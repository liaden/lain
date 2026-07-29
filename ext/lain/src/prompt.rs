//! A starship-compatible prompt format DSL: parse, style, render.
//!
//! The grammar is starship's `src/formatter/spec.pest` (ISC; see
//! `ext/lain/NOTICE` for the attribution the vendored grammar requires) --
//! four productions, reproduced in `planning/chat-ux-research-2026-07.md`
//! section 6.1:
//!
//! ```text
//! expression   = _{ SOI ~ value* ~ EOI }
//! value        = _{ text | variable | textgroup | conditional }
//! variable     = { "$" ~ (variable_name | variable_scope) }
//! textgroup    = { "[" ~ format ~ "]" ~ "(" ~ style ~ ")" }
//! format       = { value* }
//! style        = { (variable | string)* }
//! conditional  = { "(" ~ format ~ ")" }
//! escaped_char = { "[" | "]" | "(" | ")" | "\\" | "$" }
//! ```
//!
//! ## Why hand-rolled, and not `pest`
//!
//! Deliberate, and against this project's usual "prefer a mature crate" rule.
//! Four productions with no left recursion, no precedence and no lookahead
//! beyond one byte is the exact shape recursive descent was invented for -- the
//! parser below is under 200 lines. `pest` would take the grammar nearly
//! verbatim but adds a proc-macro dependency, a build step, and an error type
//! whose positions we would still have to re-word for a Ruby-facing message.
//! The research pass reached the same conclusion in advance ("hand-rolled
//! recursive descent at zero dependencies is genuinely reasonable at four
//! productions"). The tradeoff is that the grammar now lives in two places --
//! the doc comment above and the code below -- so a change to one is a change
//! to both.
//!
//! ## The architectural line: color is an argument, never a discovery
//!
//! Nothing in this module reads `NO_COLOR`, `FORCE_COLOR`, `TERM`, or asks
//! whether a file descriptor is a tty, and neither does any crate it reaches:
//! `anstyle` is style VALUE TYPES with zero runtime dependencies. Those are all
//! properties of the stream **Ruby** owns. Color arrives resolved, as the
//! `color` argument, which is what keeps [`Format::render`] a pure
//! `(format, vars, color) -> String`. `deny.toml`'s `[bans]` list enforces the
//! negative half of that statement for the whole workspace.
//!
//! ## Testing shape
//!
//! No `magnus` type appears in any signature here, so the parser, the style
//! vocabulary, elision, width, and the config loader are all exercised by
//! `cargo test` without an embedded Ruby VM. The FFI surface is the `ffi`
//! submodule at the bottom, and it holds no logic beyond value conversion.

use anstyle::{Ansi256Color, AnsiColor, Color, Effects, RgbColor, Style};
use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;
use unicode_width::UnicodeWidthStr;

/// The characters the grammar reserves. A literal one of these in text must be
/// backslash-escaped, and `escaped_char` accepts exactly this set plus `\\`.
const SPECIAL: [char; 6] = ['[', ']', '(', ')', '$', '\\'];

/// How deeply `[...]` and `(...)` groups may nest before a format is refused.
///
/// This bound is a SAFETY property, not a style preference. `Parser::format`
/// recurses through `text_group`/`conditional`, and so do the three AST walks
/// and the `Vec<Element>` drop glue; unbounded, `"((((..."` overflows the stack
/// at roughly 10 300 levels. Ruby's guard-page handler turns that into a
/// `SystemStackError`, which sounds survivable and is not: it longjmps through
/// live Rust frames, so no destructor runs and every allocation below the jump
/// leaks (measured: 16 MB over 200 overflowed compiles, never reclaimed). On a
/// build without that handler, and on the smaller stacks a `Thread` gets, it is
/// a SIGSEGV that takes the whole REPL down.
///
/// 64 is far past any legible prompt -- starship's own shipped presets do not
/// exceed four -- and shallow enough that the deepest legal parse uses a few
/// kilobytes of stack. Because a [`Format`] can ONLY be built by
/// [`Format::parse`], bounding the parse bounds every later walk over the same
/// tree -- `render_elements`, `any_variable_set`, `collect_variables`, and the
/// `Vec<Element>` drop glue -- so there is one limit here rather than four.
///
/// **Scope: this bounds [`Format`], and nothing else in this file.** [`Setting`]
/// recurses too -- building it from TOML, rebuilding it as Ruby values, and its
/// own drop glue -- and that recursion is bounded by the `toml` crate's parser
/// instead (`max recursion depth met` for nested arrays, `recursion limit` for
/// dotted keys). Relying on a dependency's internal limit is fine; relying on it
/// silently is not, so `deeply_nested_settings_are_refused_by_the_toml_parser_not_by_us`
/// pins the behaviour we are depending on and fails if an upgrade drops it.
pub const MAX_DEPTH: usize = 64;

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

/// One `value` production: the four things a format can be made of.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Element {
    /// Literal text, with escapes already resolved.
    Text(String),
    /// `$name` or `${scope.name}`.
    Variable(String),
    /// `[format](style)` -- a styled span.
    TextGroup {
        /// The nested `format` production between the brackets.
        body: Vec<Element>,
        /// The `style` production between the parentheses.
        style: Vec<StyleToken>,
    },
    /// `(format)` -- elided entirely unless some variable inside it is set.
    Conditional(Vec<Element>),
}

/// One item of a `style` production: a literal word or a `$variable` that
/// supplies style words at render time (starship's `[$x]($style)` idiom, which
/// is how a `Frontend::Theme` token reaches the formatter).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StyleToken {
    /// A literal style word, e.g. `bold` or `fg:#ff0000`.
    Literal(String),
    /// A variable whose value is splittable into style words.
    Variable(String),
}

/// A compiled format: the parsed elements plus the source they came from.
///
/// Deliberately plain owned state -- `Vec`, `String`, C-like enums -- with no
/// cell, lock, cache, or reachable Ruby object anywhere in it. That is what
/// lets the FFI wrapper hold an `Arc<Format>` and promise `frozen_shareable`
/// honestly, the same audit `bm25.rs` records for its index.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Format {
    elements: Vec<Element>,
    source: String,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// A refusal to compile a format, always naming a byte offset into the source.
/// "Refused, not silently mangled" is the contract: there is no lenient mode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError {
    /// Byte offset into the format source where the problem was detected.
    pub offset: usize,
    /// What was wrong there.
    pub kind: ParseErrorKind,
}

/// The distinguishable ways a format source can be wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseErrorKind {
    /// Groups nested deeper than [`MAX_DEPTH`].
    TooDeep(usize),
    /// A `[` with no matching `]`, or a `(` with no matching `)`.
    Unclosed(char),
    /// A `]` or `)` with nothing open.
    Unexpected(char),
    /// `[format]` was not followed by `(style)`.
    MissingStyle,
    /// `$` not followed by a name, or `${` not closed.
    BadVariable,
    /// `\` followed by something outside `escaped_char`.
    BadEscape(char),
    /// A literal style word this vocabulary does not know.
    UnknownStyleWord(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let what = match &self.kind {
            ParseErrorKind::TooDeep(limit) => {
                format!("groups nested deeper than the limit of {limit}")
            }
            ParseErrorKind::Unclosed(c) => format!("unclosed {c:?}"),
            ParseErrorKind::Unexpected(c) => format!("unexpected {c:?}"),
            ParseErrorKind::MissingStyle => "text group is missing its \"(style)\"".to_string(),
            ParseErrorKind::BadVariable => "expected a variable name after \"$\"".to_string(),
            ParseErrorKind::BadEscape(c) => format!("unknown escape {:?}", format!("\\{c}")),
            ParseErrorKind::UnknownStyleWord(word) => format!("unknown style word {word:?}"),
        };
        write!(f, "{what} at byte offset {}", self.offset)
    }
}

impl std::error::Error for ParseError {}

/// A style word that only became visible once a `$variable` supplied it, so it
/// could not be caught at parse time. Carries no offset: the offending word did
/// not come from the format source.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("unknown style word {word:?} supplied by a variable at render time")]
pub struct StyleError {
    /// The word that is not in the vocabulary.
    pub word: String,
}

/// A refusal to load a TOML config.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConfigError {
    /// The source is not valid TOML, or is missing/mistyping a field.
    #[error("invalid prompt config: {0}")]
    Toml(String),
    /// The TOML was fine but its `format` did not compile.
    #[error("invalid prompt config format: {0}")]
    Format(ParseError),
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// A scalar or container read out of the `[settings]` table.
///
/// `toml::Value` is re-projected onto this owned enum rather than stored
/// directly, so no `toml` type is reachable from the shareable handle and the
/// interior-mutability audit stops at this module's own code.
#[derive(Debug, Clone, PartialEq)]
pub enum Setting {
    /// A TOML string.
    Str(String),
    /// A TOML integer.
    Int(i64),
    /// A TOML float.
    Float(f64),
    /// A TOML boolean.
    Bool(bool),
    /// A TOML array.
    List(Vec<Setting>),
    /// A TOML table, key-ordered.
    Table(BTreeMap<String, Setting>),
}

/// A loaded prompt config: the compiled `format`, plus whatever the optional
/// `[settings]` table carried for the Ruby side to interpret.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// The compiled `format` key.
    pub format: Format,
    /// The `[settings]` table, empty when absent.
    pub settings: BTreeMap<String, Setting>,
}

/// The wire shape of the config file. `deny_unknown_fields` is the loud-failure
/// rule applied to configuration: a mistyped top-level key is an error naming
/// the key, not a setting that silently does nothing.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    format: String,
    #[serde(default)]
    settings: toml::Table,
}

impl Config {
    /// Parse a TOML document. `from_str` only -- the caller reads the file, so
    /// this crate performs no I/O and the placement rule holds.
    pub fn parse(source: &str) -> Result<Config, ConfigError> {
        let raw: RawConfig =
            toml::from_str(source).map_err(|err| ConfigError::Toml(err.message().to_string()))?;
        let format = Format::parse(&raw.format).map_err(ConfigError::Format)?;
        let settings = raw
            .settings
            .into_iter()
            .map(|(key, value)| (key, Setting::from_toml(value)))
            .collect();
        Ok(Config { format, settings })
    }
}

impl Setting {
    /// Project a `toml::Value` onto the owned enum. Datetimes have no Ruby
    /// counterpart worth inventing here, so they arrive as their TOML text.
    fn from_toml(value: toml::Value) -> Setting {
        match value {
            toml::Value::String(s) => Setting::Str(s),
            toml::Value::Integer(i) => Setting::Int(i),
            toml::Value::Float(f) => Setting::Float(f),
            toml::Value::Boolean(b) => Setting::Bool(b),
            toml::Value::Datetime(d) => Setting::Str(d.to_string()),
            toml::Value::Array(items) => {
                Setting::List(items.into_iter().map(Setting::from_toml).collect())
            }
            toml::Value::Table(table) => Setting::Table(
                table
                    .into_iter()
                    .map(|(key, value)| (key, Setting::from_toml(value)))
                    .collect(),
            ),
        }
    }
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// A single-pass recursive-descent cursor over the format source.
struct Parser<'a> {
    src: &'a str,
    pos: usize,
    /// How many groups are currently open. See [`MAX_DEPTH`] for why this is a
    /// safety property rather than a taste one.
    depth: usize,
}

impl<'a> Parser<'a> {
    fn new(src: &'a str) -> Self {
        Parser {
            src,
            pos: 0,
            depth: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.src[self.pos..].chars().next()
    }

    fn bump(&mut self) -> Option<char> {
        let next = self.peek()?;
        self.pos += next.len_utf8();
        Some(next)
    }

    fn eat(&mut self, want: char) -> bool {
        let matched = self.peek() == Some(want);
        if matched {
            self.pos += want.len_utf8();
        }
        matched
    }

    fn err<T>(&self, offset: usize, kind: ParseErrorKind) -> Result<T, ParseError> {
        Err(ParseError { offset, kind })
    }

    /// `format = { value* }`, stopping at `terminator` (or at end of input when
    /// there is none). Returns the elements; the terminator is NOT consumed.
    ///
    /// This is the ONE place the nesting bound is enforced, because it is the
    /// only entry into the mutual recursion with `text_group`/`conditional`.
    /// The counter is decremented on the way out of every path, success or
    /// failure, so a refused-then-retried parse is not stuck at the limit.
    fn format(&mut self, terminator: Option<char>) -> Result<Vec<Element>, ParseError> {
        if self.depth == MAX_DEPTH {
            return self.err(self.pos, ParseErrorKind::TooDeep(MAX_DEPTH));
        }
        self.depth += 1;
        let elements = self.values(terminator);
        self.depth -= 1;
        elements
    }

    /// The `value*` loop itself, split out only so `format` can hold the depth
    /// counter across every early return in it.
    fn values(&mut self, terminator: Option<char>) -> Result<Vec<Element>, ParseError> {
        let mut elements = Vec::new();
        while let Some(next) = self.peek() {
            if Some(next) == terminator {
                return Ok(elements);
            }
            match next {
                ']' | ')' => return self.err(self.pos, ParseErrorKind::Unexpected(next)),
                '[' => elements.push(self.text_group()?),
                '(' => elements.push(self.conditional()?),
                '$' => elements.push(Element::Variable(self.variable()?)),
                _ => elements.push(Element::Text(self.text()?)),
            }
        }
        Ok(elements)
    }

    /// `text` -- everything up to the next special character, with escapes
    /// resolved. Always consumes at least one character, because the caller
    /// only dispatches here on a non-special one.
    fn text(&mut self) -> Result<String, ParseError> {
        let mut out = String::new();
        while let Some(next) = self.peek() {
            let stop = SPECIAL.contains(&next) && next != '\\';
            if stop {
                return Ok(out);
            }
            let at = self.pos;
            self.bump();
            if next == '\\' {
                match self.bump() {
                    Some(escaped) if SPECIAL.contains(&escaped) => out.push(escaped),
                    Some(other) => return self.err(at, ParseErrorKind::BadEscape(other)),
                    None => return self.err(at, ParseErrorKind::Unclosed('\\')),
                }
            } else {
                out.push(next);
            }
        }
        Ok(out)
    }

    /// `variable = { "$" ~ (variable_name | variable_scope) }`, where a scope is
    /// the braced `${a.b}` form. The `$` is at the cursor.
    fn variable(&mut self) -> Result<String, ParseError> {
        let start = self.pos;
        self.bump();
        if self.eat('{') {
            let name_start = self.pos;
            while self.peek().is_some_and(|c| c != '}') {
                self.bump();
            }
            let name = &self.src[name_start..self.pos];
            let closed = self.eat('}');
            if !closed || !is_scope(name) {
                return self.err(start, ParseErrorKind::BadVariable);
            }
            return Ok(name.to_string());
        }
        let name_start = self.pos;
        while self.peek().is_some_and(is_name_char) {
            self.bump();
        }
        if self.pos == name_start {
            return self.err(start, ParseErrorKind::BadVariable);
        }
        Ok(self.src[name_start..self.pos].to_string())
    }

    /// `textgroup = { "[" ~ format ~ "]" ~ "(" ~ style ~ ")" }`.
    fn text_group(&mut self) -> Result<Element, ParseError> {
        let open = self.pos;
        self.bump();
        let body = self.format(Some(']'))?;
        if !self.eat(']') {
            return self.err(open, ParseErrorKind::Unclosed('['));
        }
        if !self.eat('(') {
            return self.err(self.pos, ParseErrorKind::MissingStyle);
        }
        let style_open = self.pos;
        let style = self.style(style_open)?;
        if !self.eat(')') {
            return self.err(style_open, ParseErrorKind::Unclosed('('));
        }
        Ok(Element::TextGroup { body, style })
    }

    /// `conditional = { "(" ~ format ~ ")" }`.
    fn conditional(&mut self) -> Result<Element, ParseError> {
        let open = self.pos;
        self.bump();
        let body = self.format(Some(')'))?;
        if !self.eat(')') {
            return self.err(open, ParseErrorKind::Unclosed('('));
        }
        Ok(Element::Conditional(body))
    }

    /// `style = { (variable | string)* }`. Every literal word is validated here
    /// rather than at render time, so a typo in a config is refused when the
    /// config is loaded -- the only style words that can fail later are the ones
    /// a `$variable` supplies.
    fn style(&mut self, open: usize) -> Result<Vec<StyleToken>, ParseError> {
        let mut tokens = Vec::new();
        let mut word = String::new();
        let mut word_at = self.pos;
        while let Some(next) = self.peek() {
            if next == ')' {
                push_word(&mut tokens, &mut word, word_at)?;
                return Ok(tokens);
            }
            if next == '$' {
                push_word(&mut tokens, &mut word, word_at)?;
                tokens.push(StyleToken::Variable(self.variable()?));
                word_at = self.pos;
            } else if next.is_whitespace() {
                self.bump();
                push_word(&mut tokens, &mut word, word_at)?;
                word_at = self.pos;
            } else {
                if word.is_empty() {
                    word_at = self.pos;
                }
                word.push(next);
                self.bump();
            }
        }
        self.err(open, ParseErrorKind::Unclosed('('))
    }
}

/// Flush an accumulated literal style word, validating it against the
/// vocabulary before it is kept.
fn push_word(tokens: &mut Vec<StyleToken>, word: &mut String, at: usize) -> Result<(), ParseError> {
    if word.is_empty() {
        return Ok(());
    }
    let taken = std::mem::take(word);
    if style_word(&taken).is_none() {
        return Err(ParseError {
            offset: at,
            kind: ParseErrorKind::UnknownStyleWord(taken),
        });
    }
    tokens.push(StyleToken::Literal(taken));
    Ok(())
}

/// `variable_name` characters.
fn is_name_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// `variable_scope` -- dot-SEPARATED name segments, e.g. `git.branch`.
///
/// Every segment must be non-empty. Checking only "each character is a name
/// character or a dot" is the weaker condition that accepted `${.}`, `${...}`
/// and `${a..b}` as variables with no name in them.
fn is_scope(name: &str) -> bool {
    !name.is_empty()
        && name
            .split('.')
            .all(|segment| !segment.is_empty() && segment.chars().all(is_name_char))
}

// ---------------------------------------------------------------------------
// Style vocabulary
// ---------------------------------------------------------------------------

/// What a single style word does to a style. `None` is the whole vocabulary
/// check: an unrecognised word never silently no-ops.
enum StyleWord {
    /// Clears everything and wins over every other word in the run.
    None,
    /// Adds a text effect.
    Effect(Effects),
    /// Sets the foreground.
    Fg(Color),
    /// Sets the background.
    Bg(Color),
}

/// Classify one style word. The vocabulary is starship's: effect names, the
/// eight ANSI colors plus `bright-` variants, `fg:`/`bg:` prefixes, `#rrggbb`
/// hex, and a bare `0`-`255` ANSI-256 index.
fn style_word(word: &str) -> Option<StyleWord> {
    let lower = word.to_ascii_lowercase();
    match lower.as_str() {
        "none" => return Some(StyleWord::None),
        "bold" => return Some(StyleWord::Effect(Effects::BOLD)),
        "italic" => return Some(StyleWord::Effect(Effects::ITALIC)),
        "underline" => return Some(StyleWord::Effect(Effects::UNDERLINE)),
        "dimmed" | "dim" => return Some(StyleWord::Effect(Effects::DIMMED)),
        "blink" => return Some(StyleWord::Effect(Effects::BLINK)),
        "hidden" => return Some(StyleWord::Effect(Effects::HIDDEN)),
        "strikethrough" => return Some(StyleWord::Effect(Effects::STRIKETHROUGH)),
        "inverted" | "reversed" => return Some(StyleWord::Effect(Effects::INVERT)),
        _ => {}
    }
    match lower.split_once(':') {
        Some(("fg", rest)) => color_word(rest).map(StyleWord::Fg),
        Some(("bg", rest)) => color_word(rest).map(StyleWord::Bg),
        Some(_) => None,
        None => color_word(&lower).map(StyleWord::Fg),
    }
}

/// Classify one color word: a name, `#rrggbb`, or an ANSI-256 index.
fn color_word(word: &str) -> Option<Color> {
    let named = match word {
        "black" => Some(AnsiColor::Black),
        "red" => Some(AnsiColor::Red),
        "green" => Some(AnsiColor::Green),
        "yellow" => Some(AnsiColor::Yellow),
        "blue" => Some(AnsiColor::Blue),
        // starship spells the fifth color `purple`; ANSI and anstyle call it
        // magenta. Both names are accepted so a starship config ports verbatim.
        "purple" | "magenta" => Some(AnsiColor::Magenta),
        "cyan" => Some(AnsiColor::Cyan),
        "white" => Some(AnsiColor::White),
        "bright-black" => Some(AnsiColor::BrightBlack),
        "bright-red" => Some(AnsiColor::BrightRed),
        "bright-green" => Some(AnsiColor::BrightGreen),
        "bright-yellow" => Some(AnsiColor::BrightYellow),
        "bright-blue" => Some(AnsiColor::BrightBlue),
        "bright-purple" | "bright-magenta" => Some(AnsiColor::BrightMagenta),
        "bright-cyan" => Some(AnsiColor::BrightCyan),
        "bright-white" => Some(AnsiColor::BrightWhite),
        _ => None,
    };
    named
        .map(Color::Ansi)
        .or_else(|| hex_color(word))
        .or_else(|| ansi256(word))
}

/// A bare `0`-`255` ANSI-256 index.
///
/// The digit check is not redundant with `u8::from_str`: that accepts a leading
/// `+`, so `+5` used to compile as colour 5 while `256` and `-1` were refused --
/// a vocabulary quietly wider than the one documented.
fn ansi256(word: &str) -> Option<Color> {
    let digits = !word.is_empty() && word.chars().all(|c| c.is_ascii_digit());
    digits
        .then(|| word.parse::<u8>().ok())
        .flatten()
        .map(|n| Color::Ansi256(Ansi256Color(n)))
}

/// `#rrggbb` -> a 24-bit color.
fn hex_color(word: &str) -> Option<Color> {
    let digits = word.strip_prefix('#')?;
    if digits.len() != 6 || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let byte = |at: usize| u8::from_str_radix(&digits[at..at + 2], 16).ok();
    Some(Color::Rgb(RgbColor(byte(0)?, byte(2)?, byte(4)?)))
}

/// Fold a whitespace-separated run of style words into a [`Style`].
///
/// `none` short-circuits to the default style, matching starship: it is not one
/// more word in the fold but an override of the whole run.
fn build_style(words: &str) -> Result<Style, StyleError> {
    words
        .split_whitespace()
        .try_fold(Style::new(), |style, word| match style_word(word) {
            Some(StyleWord::None) => Ok(Style::new()),
            Some(StyleWord::Effect(effect)) => Ok(style.effects(style.get_effects() | effect)),
            Some(StyleWord::Fg(color)) => Ok(style.fg_color(Some(color))),
            Some(StyleWord::Bg(color)) => Ok(style.bg_color(Some(color))),
            None => Err(StyleError {
                word: word.to_string(),
            }),
        })
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

/// Variables supplied by the caller for one render.
pub type Vars = HashMap<String, String>;

impl Format {
    /// Compile a format source, or refuse it with a position.
    pub fn parse(source: &str) -> Result<Format, ParseError> {
        let mut parser = Parser::new(source);
        // `values`, not `format`: the top level is not a group, so it must not
        // spend one of the MAX_DEPTH levels a format is allowed to nest.
        let elements = parser.values(None)?;
        Ok(Format {
            elements,
            source: source.to_string(),
        })
    }

    /// The source this format was compiled from.
    pub fn source(&self) -> &str {
        &self.source
    }

    /// Every variable the format references, in first-appearance order, without
    /// duplicates -- including the ones that only supply style words. This is
    /// how a caller knows which values are worth computing.
    pub fn variables(&self) -> Vec<String> {
        let mut names = Vec::new();
        collect_variables(&self.elements, &mut names);
        let mut seen = HashSet::new();
        names.retain(|name| seen.insert(name.clone()));
        names
    }

    /// Render to a String. Pure in its three arguments: same format, same vars,
    /// same `color` gives the same bytes in every process.
    ///
    /// **Two different injections are refused here, and they need different
    /// defences.** A variable holding `[evil](red)` cannot introduce a style,
    /// because an interpolated value is written to the OUTPUT and never fed back
    /// to the parser -- a property of the design, not a pass that can be
    /// forgotten. A variable holding `\x1b[31m` is a separate attack on the
    /// TERMINAL rather than on this grammar, and that one *is* an explicit pass:
    /// see `sanitize`.
    pub fn render(&self, vars: &Vars, color: bool) -> Result<String, StyleError> {
        let mut segments = Vec::new();
        render_elements(&self.elements, vars, Style::new(), &mut segments)?;
        Ok(serialize(&segments, color))
    }
}

/// A rendered run of text and the style it carries.
type Segment = (String, Style);

/// Walk the AST, resolving variables and elision, into styled segments.
fn render_elements(
    elements: &[Element],
    vars: &Vars,
    style: Style,
    out: &mut Vec<Segment>,
) -> Result<(), StyleError> {
    elements.iter().try_for_each(|element| match element {
        Element::Text(text) => {
            out.push((text.clone(), style));
            Ok(())
        }
        Element::Variable(name) => {
            out.push((lookup(vars, name).unwrap_or_default().into_owned(), style));
            Ok(())
        }
        // The innermost style wins outright: it REPLACES the enclosing one
        // rather than merging with it. Characterization, not a law -- it is what
        // makes `[a[b](bold)](red)` legible, and the alternative (inheriting
        // effects across a nested group) has no matching starship behaviour.
        Element::TextGroup { body, style: spec } => {
            let resolved = resolve_style(spec, vars)?;
            render_elements(body, vars, resolved, out)
        }
        Element::Conditional(body) => {
            if any_variable_set(body, vars) {
                render_elements(body, vars, style, out)
            } else {
                Ok(())
            }
        }
    })
}

/// Join a style spec's literal and variable-supplied words, then fold them.
fn resolve_style(spec: &[StyleToken], vars: &Vars) -> Result<Style, StyleError> {
    let words = spec
        .iter()
        .map(|token| match token {
            StyleToken::Literal(word) => Cow::Borrowed(word.as_str()),
            StyleToken::Variable(name) => lookup(vars, name).unwrap_or_default(),
        })
        .collect::<Vec<_>>()
        .join(" ");
    build_style(&words)
}

/// A variable's value: sanitized, and with an empty result treated as absent.
///
/// Emptiness IS unsetness: a caller that publishes `""` for a metric it could
/// not compute gets the same elision as one that omits the key, which is what
/// makes a conditional group usable from Ruby without nil-vs-empty bookkeeping.
/// Sanitizing HERE rather than at the point of interpolation is deliberate --
/// elision, style resolution and width then all agree about what the value is,
/// and a value of nothing but control bytes elides rather than rendering an
/// empty group.
fn lookup<'a>(vars: &'a Vars, name: &str) -> Option<Cow<'a, str>> {
    let value = sanitize(vars.get(name)?);
    (!value.is_empty()).then_some(value)
}

/// Remove every control character from an interpolated value.
///
/// **This is a security control, and it is the one the format-syntax argument
/// does NOT cover.** A value cannot inject *lain's* grammar because it is never
/// re-parsed, but it reaches a terminal verbatim, and a terminal has its own
/// grammar: `\x1b[31m` sets a colour the caller did not choose, `\x1b[2J` clears
/// the screen, `\x1b]0;…\x07` rewrites the window title. The values T13
/// interpolates are a cwd, a git branch and a model id, and a directory name
/// containing an ESC byte is perfectly legal on Linux -- so this is reachable by
/// ordinary means, not only by an attacker.
///
/// `char::is_control` is exactly the Unicode **Cc** category: C0
/// (`U+0000`-`U+001F`), DEL, and C1 (`U+0080`-`U+009F`, whose members are 8-bit
/// CSI introducers on some terminals). Nothing in Cc has a display meaning in a
/// prompt.
///
/// **What this deliberately does NOT cover: Cf, and bidi in particular.** U+202E
/// RIGHT-TO-LEFT OVERRIDE survives, so a branch named `main\u{202e}gnp` displays
/// its tail reversed, running past the `>` terminator -- and a branch name is
/// attacker-supplied in a cloned repo, which is exactly the value class this
/// function exists for. That is accepted with eyes open: it is visual confusion,
/// not execution and not process death, and stripping Cf wholesale would take
/// the ZWJ (`U+200D`) sequences that `display_width` is deliberately built to
/// measure correctly. A narrower bidi-only rule is a real option later; it is
/// not this function's claim today.
///
/// **Stripped, not rejected, and not replaced.** Rejecting would let a directory
/// name take the prompt down, which hands an availability failure to whoever
/// controls a filename. Stripping leaves the printable remainder visible --
/// `\x1b[31mRED\x1b[0m` renders as `[31mRED[0m` -- so a hostile value shows up
/// as obvious junk instead of being silently deleted or silently obeyed.
///
/// The format SOURCE is not sanitized: it is author-written config, and a
/// literal newline in it is how a multi-line prompt is spelled.
fn sanitize(value: &str) -> Cow<'_, str> {
    if value.chars().any(char::is_control) {
        Cow::Owned(value.chars().filter(|c| !c.is_control()).collect())
    } else {
        Cow::Borrowed(value)
    }
}

/// The conditional's whole rule: show the group only if some variable anywhere
/// inside it -- nested groups and conditionals included -- resolves non-empty.
///
/// A group containing NO variable therefore elides. That is starship's
/// behaviour (its predicate is an `any` over variables, vacuously false) and it
/// is pinned by a characterization test rather than inferred at each reading.
fn any_variable_set(elements: &[Element], vars: &Vars) -> bool {
    elements.iter().any(|element| match element {
        Element::Text(_) => false,
        Element::Variable(name) => lookup(vars, name).is_some(),
        Element::TextGroup { body, .. } => any_variable_set(body, vars),
        Element::Conditional(body) => any_variable_set(body, vars),
    })
}

/// Gather variable names depth-first, style variables included.
fn collect_variables(elements: &[Element], out: &mut Vec<String>) {
    elements.iter().for_each(|element| match element {
        Element::Text(_) => {}
        Element::Variable(name) => out.push(name.clone()),
        Element::TextGroup { body, style } => {
            collect_variables(body, out);
            style.iter().for_each(|token| {
                if let StyleToken::Variable(name) = token {
                    out.push(name.clone());
                }
            });
        }
        Element::Conditional(body) => collect_variables(body, out),
    });
}

/// Turn styled segments into the final String.
///
/// With `color` false the styles are simply dropped, so the output is the
/// plain text and provably carries no escape sequence -- there is no stripping
/// pass that could miss one. Each styled segment is self-delimiting (prefix,
/// text, reset), which is what keeps a nested group from leaking its style into
/// the text that follows.
fn serialize(segments: &[Segment], color: bool) -> String {
    segments
        .iter()
        .filter(|(text, _)| !text.is_empty())
        .map(|(text, style)| {
            if color && *style != Style::new() {
                format!("{}{text}{}", style.render(), style.render_reset())
            } else {
                text.clone()
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Width
// ---------------------------------------------------------------------------

/// Display columns a rendered prompt occupies, for the line editor's cursor
/// arithmetic.
///
/// Three corrections over `String#length`. Escape sequences contribute zero;
/// so does every other control character; and width is then taken over the whole
/// remaining `str` in ONE call, because `unicode-width` 0.2 stopped defining it
/// as the sum of per-`char` widths -- which is what makes a ZWJ emoji sequence
/// or a variation selector count once. Building the cleaned string first is what
/// buys that last property: measuring fragment-by-fragment would reintroduce the
/// summing this exists to avoid.
///
/// The escape skipper is a deliberate hand-roll rather than a
/// `strip-ansi-escapes`/`vte` dependency: the ONLY sequences that can appear
/// here are the SGR ones this module's own `serialize` emitted, so a full
/// terminal-protocol parser would be answering a question we do not have. It
/// skips CSI (`ESC [` .. final byte) and OSC (`ESC ]` .. BEL or `ESC \`), and
/// nothing else claims to be handled -- anything it does not recognise still
/// contributes nothing, because the stray control characters are dropped anyway.
pub fn display_width(text: &str) -> usize {
    let mut cleaned = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(escape) = rest.find('\u{1b}') {
        cleaned.push_str(&rest[..escape]);
        rest = &rest[escape..];
        // A lone ESC with nothing recognisable after it skips just the ESC, so
        // the loop always advances.
        rest = &rest[skip_escape(rest).max('\u{1b}'.len_utf8())..];
    }
    cleaned.push_str(rest);
    cleaned.retain(|c| !c.is_control());
    cleaned.width()
}

/// Byte length of the escape sequence starting at `rest`, or 0 if it is not one
/// this function claims to understand.
fn skip_escape(rest: &str) -> usize {
    let mut chars = rest.char_indices();
    chars.next();
    match chars.next() {
        Some((_, '[')) => chars
            .find(|(_, c)| ('\u{40}'..='\u{7e}').contains(c))
            .map_or(rest.len(), |(at, c)| at + c.len_utf8()),
        Some((_, ']')) => match chars.find(|(_, c)| *c == '\u{7}' || *c == '\u{1b}') {
            // OSC ends at BEL, or at ST -- which is TWO bytes, `ESC \`. Stopping
            // after the ESC left the backslash to be counted as a column, and
            // T13 places a cursor with this number.
            Some((at, '\u{1b}')) => {
                let after_escape = at + '\u{1b}'.len_utf8();
                after_escape + usize::from(rest[after_escape..].starts_with('\\'))
            }
            Some((at, terminator)) => at + terminator.len_utf8(),
            None => rest.len(),
        },
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars(pairs: &[(&str, &str)]) -> Vars {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    }

    fn render(source: &str, pairs: &[(&str, &str)], color: bool) -> String {
        Format::parse(source)
            .expect("format parses")
            .render(&vars(pairs), color)
            .expect("format renders")
    }

    // -- the card's acceptance criteria ------------------------------------

    #[test]
    fn a_text_group_carries_its_style() {
        let out = render("[lain](bold green) ", &[], true);
        // anstyle emits ONE SGR sequence per attribute (`ESC[1m ESC[32m`), not a
        // combined `ESC[1;32m`. Both are valid SGR; the exact bytes are pinned
        // here so a crate upgrade that changes them is visible rather than
        // silently reshaping every prompt.
        assert_eq!(out, "\u{1b}[1m\u{1b}[32mlain\u{1b}[0m ");
    }

    #[test]
    fn a_variable_interpolates() {
        assert_eq!(
            render("$model", &[("model", "qwen3:4b")], false),
            "qwen3:4b"
        );
    }

    #[test]
    fn a_conditional_elides_when_every_variable_inside_it_is_empty() {
        assert_eq!(render("a(-$missing-)b", &[], false), "ab");
    }

    #[test]
    fn a_conditional_survives_when_any_variable_inside_it_is_set() {
        assert_eq!(
            render("a(-$present-)b", &[("present", "x")], false),
            "a-x-b"
        );
    }

    #[test]
    fn color_disabled_emits_no_escape_sequences() {
        let out = render("[x](red)", &[], false);
        assert_eq!(out, "x");
        assert!(!out.contains('\u{1b}'));
    }

    #[test]
    fn an_interpolated_value_cannot_inject_format_syntax() {
        let out = render("$evil", &[("evil", "[evil](red)")], true);
        assert_eq!(out, "[evil](red)");
        assert!(!out.contains('\u{1b}'));
    }

    #[test]
    fn a_malformed_format_is_refused_with_a_position() {
        let err = Format::parse("[unclosed").expect_err("refused");
        assert_eq!(err.offset, 0);
        assert!(
            err.to_string().contains("byte offset 0"),
            "message names the position: {err}"
        );
    }

    // -- recursion depth ---------------------------------------------------
    //
    // From the review probe `.review-T10/probe_depth2.rb`, which measured an
    // unbounded parser surviving depth 10 000 and overflowing at 10 312.

    #[test]
    fn nesting_past_the_limit_is_refused_rather_than_overflowing_the_stack() {
        let source = "(".repeat(MAX_DEPTH + 1);
        let err = Format::parse(&source).expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::TooDeep(MAX_DEPTH));
    }

    #[test]
    fn a_deeply_nested_text_group_is_refused_on_depth_not_on_closure() {
        let err = Format::parse(&"[".repeat(MAX_DEPTH + 1)).expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::TooDeep(MAX_DEPTH));
    }

    #[test]
    fn the_probe_depth_that_used_to_overflow_is_now_a_plain_parse_error() {
        let err = Format::parse(&"(".repeat(20_000)).expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::TooDeep(MAX_DEPTH));
    }

    // Every walk over the AST -- render, elision, variable collection, and the
    // Vec<Element> drop glue -- recurses too. They inherit the parser's bound
    // because a Format is only constructible through `parse`; this exercises the
    // deepest legal tree through all of them to keep that inheritance honest.
    #[test]
    fn every_walk_survives_a_format_nested_to_the_limit() {
        let source = format!("{}$x{}", "(".repeat(MAX_DEPTH), ")".repeat(MAX_DEPTH));
        let format = Format::parse(&source).expect("parses at the limit");
        assert_eq!(format.variables(), vec!["x"]);
        assert_eq!(
            format.render(&vars(&[("x", "y")]), true).expect("renders"),
            "y"
        );
        assert_eq!(format.render(&vars(&[]), true).expect("renders"), "");
    }

    // -- escape-byte injection ---------------------------------------------
    //
    // A DIFFERENT attack from `an_interpolated_value_cannot_inject_format_syntax`
    // above: that one covers lain's own format syntax, this one covers the
    // TERMINAL's. Both are needed. Values reaching T13 include a cwd, a git
    // branch and a model id, and a directory name containing an ESC byte is
    // legal on Linux.

    #[test]
    fn a_value_cannot_smuggle_sgr_through_an_uncolored_render() {
        let out = render("$x", &[("x", "\u{1b}[31mRED\u{1b}[0m")], false);
        assert!(!out.contains('\u{1b}'), "{out:?}");
        assert_eq!(out, "[31mRED[0m");
    }

    #[test]
    fn a_value_cannot_clear_the_screen_or_retitle_the_terminal() {
        assert_eq!(render("$x", &[("x", "\u{1b}[2J")], false), "[2J");
        assert_eq!(
            render("$x", &[("x", "\u{1b}]0;title\u{7}")], false),
            "]0;title"
        );
    }

    #[test]
    fn a_value_is_sanitized_with_color_enabled_too() {
        let out = render("[$x](red)", &[("x", "\u{1b}[2J")], true);
        assert_eq!(out, "\u{1b}[31m[2J\u{1b}[0m");
    }

    #[test]
    fn every_c0_and_c1_control_is_removed_from_a_value() {
        let hostile: String = (0..=0x9fu32)
            .filter_map(char::from_u32)
            .filter(|c| c.is_control())
            .collect();
        let out = render("$x", &[("x", &hostile)], false);
        assert_eq!(out, "");
    }

    #[test]
    fn a_value_of_nothing_but_control_bytes_counts_as_unset() {
        assert_eq!(render("a(-$x-)b", &[("x", "\u{1b}\u{7}")], false), "ab");
    }

    // The format SOURCE is author-controlled config, not untrusted input, so a
    // literal newline in it survives -- that is how a multi-line prompt is
    // written. Only interpolated VALUES are sanitized.
    #[test]
    fn literal_text_from_the_format_source_is_not_sanitized() {
        assert_eq!(render("a\nb", &[], false), "a\nb");
    }

    // -- parser ------------------------------------------------------------

    #[test]
    fn an_unexpected_closing_bracket_names_its_position() {
        let err = Format::parse("ok]").expect_err("refused");
        assert_eq!(err.offset, 2);
        assert_eq!(err.kind, ParseErrorKind::Unexpected(']'));
    }

    #[test]
    fn a_text_group_without_a_style_is_refused() {
        let err = Format::parse("[x]").expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::MissingStyle);
    }

    #[test]
    fn an_unclosed_style_is_refused() {
        let err = Format::parse("[x](red").expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::Unclosed('('));
    }

    #[test]
    fn a_bare_dollar_is_refused() {
        let err = Format::parse("cost: $").expect_err("refused");
        assert_eq!(err.offset, 6);
        assert_eq!(err.kind, ParseErrorKind::BadVariable);
    }

    #[test]
    fn an_unknown_escape_is_refused() {
        let err = Format::parse("a\\qb").expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::BadEscape('q'));
    }

    #[test]
    fn escaped_specials_are_literal_text() {
        assert_eq!(render("\\[a\\]\\(b\\)\\$c\\\\", &[], false), "[a](b)$c\\");
    }

    #[test]
    fn a_braced_variable_scope_parses() {
        assert_eq!(
            render("${git.branch}", &[("git.branch", "main")], false),
            "main"
        );
    }

    #[test]
    fn an_unterminated_scope_is_refused() {
        let err = Format::parse("${git.branch").expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::BadVariable);
    }

    // A scope is dot-SEPARATED name segments, so every segment must be non-empty.
    // Checking only `all(is_scope_char)` accepted a variable with no name
    // character in it at all.
    #[test]
    fn a_scope_of_dots_or_with_an_empty_segment_is_refused() {
        ["${.}", "${...}", "${a..b}", "${a.}", "${.a}", "${}"]
            .iter()
            .for_each(|source| {
                let err = Format::parse(source).expect_err(source);
                assert_eq!(err.kind, ParseErrorKind::BadVariable, "{source}");
            });
    }

    #[test]
    fn a_well_formed_scope_still_parses() {
        ["${a}", "${a.b}", "${a.b.c}", "${a_1.b_2}"]
            .iter()
            .for_each(|source| {
                Format::parse(source).unwrap_or_else(|err| panic!("{source}: {err}"));
            });
    }

    #[test]
    fn nesting_composes() {
        let format = Format::parse("[a($b)c](red)").expect("parses");
        assert_eq!(
            format.elements,
            vec![Element::TextGroup {
                body: vec![
                    Element::Text("a".to_string()),
                    Element::Conditional(vec![Element::Variable("b".to_string())]),
                    Element::Text("c".to_string()),
                ],
                style: vec![StyleToken::Literal("red".to_string())],
            }]
        );
    }

    #[test]
    fn the_source_is_retained() {
        assert_eq!(Format::parse("$a b").expect("parses").source(), "$a b");
    }

    // -- variables ---------------------------------------------------------

    #[test]
    fn variables_are_listed_once_in_first_appearance_order() {
        let format = Format::parse("$b [$a$b]($style) ($a)").expect("parses");
        assert_eq!(format.variables(), vec!["b", "a", "style"]);
    }

    #[test]
    fn an_unset_variable_renders_empty() {
        assert_eq!(render("<$nope>", &[], false), "<>");
    }

    // -- conditionals ------------------------------------------------------

    #[test]
    fn an_empty_string_counts_as_unset() {
        assert_eq!(render("a($x)b", &[("x", "")], false), "ab");
    }

    #[test]
    fn a_conditional_sees_a_variable_inside_a_nested_text_group() {
        assert_eq!(
            render("([$x](red))", &[("x", "hi")], false),
            "hi",
            "the nested group's variable keeps the conditional alive"
        );
    }

    // CHARACTERIZATION, not a declared law: a conditional with no variable at
    // all elides, because the predicate is `any` over variables and is
    // vacuously false. Matches starship. Pinned so a refactor cannot flip it in
    // silence.
    #[test]
    fn a_conditional_with_no_variables_elides() {
        assert_eq!(render("a(plain)b", &[], false), "ab");
    }

    // -- style vocabulary --------------------------------------------------

    #[test]
    fn an_unknown_literal_style_word_is_refused_at_parse_time() {
        let err = Format::parse("[x](chartreuse)").expect_err("refused");
        assert_eq!(
            err.kind,
            ParseErrorKind::UnknownStyleWord("chartreuse".to_string())
        );
    }

    #[test]
    fn fg_and_bg_prefixes_parse() {
        let style = build_style("fg:#ff0000 bg:4").expect("known words");
        assert_eq!(style.get_fg_color(), Some(Color::Rgb(RgbColor(255, 0, 0))));
        assert_eq!(style.get_bg_color(), Some(Color::Ansi256(Ansi256Color(4))));
    }

    // `u8::from_str` accepts a leading `+`, so the vocabulary was quietly wider
    // than it claimed: `+5` compiled as ANSI-256 colour 5 while `256` and `-1`
    // were correctly refused. An index is plain digits.
    #[test]
    fn an_ansi256_index_must_be_plain_digits() {
        ["0", "5", "255"]
            .iter()
            .for_each(|word| assert!(build_style(word).is_ok(), "{word}"));
        ["+5", "256", "-1", "0x5", "5_"]
            .iter()
            .for_each(|word| assert!(build_style(word).is_err(), "{word}"));
    }

    #[test]
    fn a_plus_prefixed_index_is_refused_at_parse_time_too() {
        let err = Format::parse("[x](+5)").expect_err("refused");
        assert_eq!(err.kind, ParseErrorKind::UnknownStyleWord("+5".to_string()));
    }

    #[test]
    fn purple_and_magenta_name_the_same_color() {
        assert_eq!(
            build_style("purple").expect("known").get_fg_color(),
            build_style("magenta").expect("known").get_fg_color()
        );
    }

    #[test]
    fn none_clears_the_whole_run() {
        assert_eq!(build_style("bold red none").expect("known"), Style::new());
    }

    #[test]
    fn a_style_variable_resolves_at_render_time() {
        let out = render("[x]($accent)", &[("accent", "bold red")], true);
        assert_eq!(out, "\u{1b}[1m\u{1b}[31mx\u{1b}[0m");
    }

    #[test]
    fn a_style_variable_supplying_a_bad_word_is_refused_at_render_time() {
        let err = Format::parse("[x]($accent)")
            .expect("parses")
            .render(&vars(&[("accent", "chartreuse")]), true)
            .expect_err("refused");
        assert_eq!(err.word, "chartreuse");
    }

    #[test]
    fn an_unset_style_variable_leaves_the_span_unstyled() {
        assert_eq!(render("[x]($accent)", &[], true), "x");
    }

    #[test]
    fn the_innermost_style_wins() {
        let out = render("[a[b](bold)](red)", &[], true);
        assert_eq!(out, "\u{1b}[31ma\u{1b}[0m\u{1b}[1mb\u{1b}[0m");
    }

    // -- width -------------------------------------------------------------

    #[test]
    fn width_counts_wide_glyphs_as_two_columns() {
        assert_eq!(display_width("日本"), 4);
        assert_eq!(display_width("ab"), 2);
    }

    // ST is the TWO bytes `ESC \`. Consuming only the ESC left the backslash to
    // be counted, so a title-setting sequence added a phantom column -- and T13
    // places a cursor with this number.
    #[test]
    fn width_consumes_both_bytes_of_a_string_terminator() {
        assert_eq!(display_width("\u{1b}]0;t\u{1b}\\x"), 1);
    }

    #[test]
    fn width_counts_a_control_character_as_zero_columns() {
        assert_eq!(display_width("a\u{7}b"), 2);
        assert_eq!(display_width("a\nb"), 2);
        assert_eq!(display_width("a\u{7f}b"), 2);
    }

    #[test]
    fn width_ignores_ansi_sequences() {
        let styled = render("[lain](bold green)", &[], true);
        assert_eq!(display_width(&styled), 4);
    }

    #[test]
    fn width_of_a_rendered_prompt_matches_its_uncolored_length() {
        let format = Format::parse("[$model](green) on ").expect("parses");
        let bound = vars(&[("model", "qwen3:4b")]);
        let colorful = format.render(&bound, true).expect("renders");
        let plain = format.render(&bound, false).expect("renders");
        assert_eq!(display_width(&colorful), display_width(&plain));
    }

    // -- config ------------------------------------------------------------

    #[test]
    fn a_config_carries_a_compiled_format_and_its_settings() {
        let config = Config::parse("format = \"$model \"\n[settings]\nmax_width = 40\n")
            .expect("valid config");
        assert_eq!(config.format.source(), "$model ");
        assert_eq!(config.settings.get("max_width"), Some(&Setting::Int(40)));
    }

    #[test]
    fn a_config_may_omit_settings() {
        let config = Config::parse("format = \"x\"").expect("valid config");
        assert!(config.settings.is_empty());
    }

    #[test]
    fn a_config_missing_its_format_is_refused() {
        let err = Config::parse("[settings]\na = 1\n").expect_err("refused");
        assert!(matches!(err, ConfigError::Toml(_)), "{err}");
    }

    #[test]
    fn a_config_with_an_unknown_top_level_key_is_refused() {
        let err = Config::parse("format = \"x\"\nfromat = \"y\"\n").expect_err("refused");
        assert!(err.to_string().contains("fromat"), "{err}");
    }

    // `Setting`'s three recursions -- `from_toml`, the Ruby rebuild, and its own
    // drop glue -- are bounded by the `toml` crate's parser, NOT by MAX_DEPTH,
    // which governs `Format` alone. Relying on a dependency's internal limit is
    // fine; relying on it silently is not, so this pins the behaviour we are
    // depending on and will fail if a `toml` upgrade removes it.
    #[test]
    fn deeply_nested_settings_are_refused_by_the_toml_parser_not_by_us() {
        let nested = format!(
            "format = \"x\"\n[settings]\na = {}{}\n",
            "[".repeat(500),
            "]".repeat(500)
        );
        let err = Config::parse(&nested).expect_err("refused");
        assert!(matches!(err, ConfigError::Toml(_)), "{err}");
    }

    #[test]
    fn deeply_dotted_settings_keys_are_refused_the_same_way() {
        let key = vec!["a"; 500].join(".");
        let source = format!("format = \"x\"\n[settings]\n{key} = 1\n");
        let err = Config::parse(&source).expect_err("refused");
        assert!(matches!(err, ConfigError::Toml(_)), "{err}");
    }

    #[test]
    fn a_config_whose_format_does_not_compile_is_refused() {
        let err = Config::parse("format = \"[unclosed\"").expect_err("refused");
        assert!(matches!(err, ConfigError::Format(_)), "{err}");
    }

    #[test]
    fn config_settings_project_every_toml_scalar() {
        let config = Config::parse(
            "format = \"x\"\n[settings]\ns = \"t\"\ni = 1\nf = 1.5\nb = true\nl = [1, 2]\n",
        )
        .expect("valid config");
        assert_eq!(config.settings["s"], Setting::Str("t".to_string()));
        assert_eq!(config.settings["i"], Setting::Int(1));
        assert_eq!(config.settings["f"], Setting::Float(1.5));
        assert_eq!(config.settings["b"], Setting::Bool(true));
        assert_eq!(
            config.settings["l"],
            Setting::List(vec![Setting::Int(1), Setting::Int(2)])
        );
    }

    // -- error messages ----------------------------------------------------
    //
    // Display IS the FFI-visible message for both: `ffi::style_error` and
    // `ffi::config_error` raise `err.to_string()` into the named Ruby error.
    // Pinned so a derive cannot drift a byte of it.

    #[test]
    fn style_and_config_error_displays_are_the_exact_ffi_messages() {
        assert_eq!(
            StyleError {
                word: "chartreuse".to_string()
            }
            .to_string(),
            r#"unknown style word "chartreuse" supplied by a variable at render time"#
        );
        assert_eq!(
            ConfigError::Toml("expected an equals".to_string()).to_string(),
            "invalid prompt config: expected an equals"
        );
        let refused = Format::parse("[unclosed").expect_err("refused");
        assert_eq!(
            ConfigError::Format(refused.clone()).to_string(),
            format!("invalid prompt config format: {refused}")
        );
    }

    #[test]
    fn style_and_config_errors_are_std_errors() {
        let style: Box<dyn std::error::Error> = Box::new(StyleError {
            word: "chartreuse".to_string(),
        });
        assert_eq!(
            style.to_string(),
            r#"unknown style word "chartreuse" supplied by a variable at render time"#
        );
        let config: Box<dyn std::error::Error> = Box::new(ConfigError::Toml("bad".to_string()));
        assert_eq!(config.to_string(), "invalid prompt config: bad");
    }

    // -- purity ------------------------------------------------------------

    #[test]
    fn two_renders_of_the_same_inputs_are_byte_identical() {
        let format = Format::parse("[$a](bold red) ($b) $c").expect("parses");
        let bound = vars(&[("a", "one"), ("c", "three")]);
        assert_eq!(
            format.render(&bound, true).expect("renders"),
            format.render(&bound, true).expect("renders")
        );
    }
}

#[cfg(not(test))]
pub mod ffi {
    use super::{
        Config, ConfigError, Format, ParseError, Setting, StyleError, Vars, display_width,
    };
    use crate::ffi::{frozen_str, lookup_error};
    use magnus::{
        DataTypeFunctions, Error, ExceptionClass, RArray, RHash, RModule, RString, Ruby, Symbol,
        TypedData, Value,
        encoding::{EncodingCapable, RbEncoding},
        function, method,
        prelude::*,
        r_hash::ForEach,
        scan_args::{get_kwargs, scan_args},
        typed_data::Obj,
    };
    use std::collections::BTreeMap;
    use std::sync::Arc;

    /// A compiled prompt format, frozen and `Ractor.shareable?`.
    ///
    /// Wraps only `Arc`s of plain owned Rust state -- `Vec`s, `String`s, C-like
    /// enums, and `anstyle`'s `Copy` value types. Nothing reachable from any of
    /// it is a `Cell`/`RefCell`/`Mutex`/`OnceCell`/atomic/lazy cache (`anstyle`
    /// has zero runtime dependencies, and `toml`'s own types are projected onto
    /// our `Setting` at load time so none survive into the handle), and it holds
    /// no Ruby object, so `frozen_shareable` is honest here for the same reasons
    /// `bm25.rs` records for its index. A parser scratch buffer would have broken
    /// that -- there is none: parsing happens once, in `compile`, and the cursor
    /// dies with it.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Prompt", free_immediately, frozen_shareable)]
    pub struct Prompt {
        format: Arc<Format>,
        settings: Arc<BTreeMap<String, Setting>>,
    }

    impl DataTypeFunctions for Prompt {}

    impl Prompt {
        fn wrap(ruby: &Ruby, format: Format, settings: BTreeMap<String, Setting>) -> Obj<Self> {
            let obj = ruby.obj_wrap(Prompt {
                format: Arc::new(format),
                settings: Arc::new(settings),
            });
            obj.freeze();
            obj
        }

        /// `Lain::Ext::Prompt.compile(source)` -- parse once, render many times.
        fn compile(ruby: &Ruby, source: Value) -> Result<Obj<Self>, Error> {
            let source = read_text(ruby, source, || "format source".to_string())?;
            let format = Format::parse(&source).map_err(|err| parse_error(ruby, &err))?;
            Ok(Prompt::wrap(ruby, format, BTreeMap::new()))
        }

        /// `Lain::Ext::Prompt.from_toml(source)` -- the same object, compiled from
        /// a config document. The SOURCE is passed, never a path: Ruby reads the
        /// file, so no I/O crosses the boundary.
        fn from_toml(ruby: &Ruby, source: Value) -> Result<Obj<Self>, Error> {
            let source = read_text(ruby, source, || "config source".to_string())?;
            let config = Config::parse(&source).map_err(|err| config_error(ruby, &err))?;
            Ok(Prompt::wrap(ruby, config.format, config.settings))
        }

        /// `Lain::Ext::Prompt.width(text)` -- display columns, escape sequences
        /// excluded. What the line editor needs in order to place a cursor.
        fn width(ruby: &Ruby, text: Value) -> Result<usize, Error> {
            Ok(display_width(&read_text(ruby, text, || {
                "text".to_string()
            })?))
        }

        fn source(ruby: &Ruby, rb_self: &Prompt) -> Value {
            frozen_str(ruby, rb_self.format.source())
        }

        fn variables(ruby: &Ruby, rb_self: &Prompt) -> Result<RArray, Error> {
            let names = rb_self.format.variables();
            let out = ruby.ary_new_capa(names.len());
            names
                .iter()
                .try_for_each(|name| out.push(frozen_str(ruby, name)))?;
            out.freeze();
            Ok(out)
        }

        fn settings(ruby: &Ruby, rb_self: &Prompt) -> Result<Value, Error> {
            table_to_ruby(ruby, &rb_self.settings)
        }

        /// `#render(vars, color:)` -- one FFI crossing per prompt.
        ///
        /// `color` is a REQUIRED keyword rather than a defaulted one, and that is
        /// the whole architectural line in one signature: Ruby owns the stream,
        /// so Ruby is the only party that can answer it, and a default would let
        /// a caller forget to.
        fn render(ruby: &Ruby, rb_self: &Prompt, args: &[Value]) -> Result<Value, Error> {
            let parsed = scan_args::<(RHash,), (), (), (), RHash, ()>(args)?;
            let (bindings,) = parsed.required;
            let kwargs = get_kwargs::<_, (Value,), (), ()>(parsed.keywords, &["color"], &[])?;
            let color = kwargs.required.0.to_bool();
            let vars = read_vars(ruby, bindings)?;
            let rendered = rb_self
                .format
                .render(&vars, color)
                .map_err(|err| style_error(ruby, &err))?;
            Ok(frozen_str(ruby, &rendered))
        }
    }

    /// Read the variable bindings Hash. `nil` means unset, which renders
    /// identically to an empty String; everything else goes through the same
    /// `read_text` every other entry point uses.
    fn read_vars(ruby: &Ruby, bindings: RHash) -> Result<Vars, Error> {
        let mut vars = Vars::new();
        bindings.foreach(|key: Value, value: Value| {
            let name = read_text(ruby, key, || "variable name".to_string())?;
            let bound = if value.is_nil() {
                String::new()
            } else {
                read_text(ruby, value, || format!("value for {name:?}"))?
            };
            vars.insert(name, bound);
            Ok(ForEach::Continue)
        })?;
        Ok(vars)
    }

    /// **The only way text enters this binding.** `compile`, `from_toml`,
    /// `width`, and every key and value of `render`'s Hash all come through
    /// here, so there is exactly one string-boundary policy to reason about.
    ///
    /// Two earlier defects are why it is one function rather than magnus's
    /// `String` conversion at each site. First, that conversion accepted
    /// `"abc".encode("UTF-16LE")` and reinterpreted its bytes `61 00 62 00 63 00`
    /// as UTF-8 -- silent mangling, and NUL is valid UTF-8 so byte validation
    /// alone would not have caught it; the ENCODING has to be checked. Second,
    /// the failures it did produce raised out of `Canonical`, so a caller nowhere
    /// near `Canonical` had to rescue a `Canonical` error. Both are why this does
    /// not reuse `lib.rs`'s `coerce_text`: the policy here is strictly stricter
    /// and the taxonomy is deliberately different.
    ///
    /// The accepted set is "encodings whose bytes ARE the text", so reading them
    /// as UTF-8 is identity and never a transcode: UTF-8, US-ASCII, and BINARY
    /// when its bytes happen to be valid UTF-8. UTF-16LE declares a different
    /// meaning for the same bytes and is refused by name. Symbols are accepted
    /// for the same reason `read_role` accepts them.
    ///
    /// `what` is a closure so the only caller that has to BUILD its label --
    /// `read_vars`, once per variable per prompt -- pays for it on the error
    /// path alone. The message deliberately does not offer `nil`: `nil` is legal
    /// only as a variable value, and `read_vars` answers that before calling
    /// here, so there is no reachable state in which this text could truthfully
    /// advertise it.
    fn read_text(ruby: &Ruby, value: Value, what: impl Fn() -> String) -> Result<String, Error> {
        let symbol_text = Symbol::from_value(value)
            .map(|symbol| symbol.funcall::<_, _, RString>("to_s", ()))
            .transpose()?;
        let string = RString::from_value(value).or(symbol_text).ok_or_else(|| {
            // SAFETY: see `ruby_to_canon` in lib.rs -- `classname` borrows
            // from the object, which is rooted for the duration of this call,
            // and no Ruby code runs meanwhile.
            let class = unsafe { value.classname() }.into_owned();
            Error::new(
                ruby.exception_type_error(),
                format!(
                    "{} must be a String or Symbol, got {}",
                    what(),
                    with_article(&class)
                ),
            )
        })?;
        let encoding = string.enc_get();
        let byte_transparent = encoding == ruby.utf8_encindex()
            || encoding == ruby.usascii_encindex()
            || encoding == ruby.ascii8bit_encindex();
        if !byte_transparent {
            return Err(Error::new(
                ruby.exception_encoding_error(),
                format!(
                    "{} must be UTF-8, got {}",
                    what(),
                    RbEncoding::from(encoding).name()
                ),
            ));
        }
        // SAFETY: `as_str` borrows the String's buffer, which is rooted by
        // `value` for the duration of this call; the bytes are copied out before
        // returning and no Ruby code runs meanwhile.
        unsafe { string.as_str() }.map(str::to_owned).map_err(|_| {
            Error::new(
                ruby.exception_encoding_error(),
                format!("{} is not valid UTF-8", what()),
            )
        })
    }

    /// `"Integer"` -> `"an Integer"`, `"Float"` -> `"a Float"`. Ruby class names
    /// are always capitalised, so first-letter vowel is the whole rule.
    fn with_article(class: &str) -> String {
        let vowel = class
            .chars()
            .next()
            .is_some_and(|first| "AEIOU".contains(first));
        format!("{} {class}", if vowel { "an" } else { "a" })
    }

    /// Rebuild the `[settings]` table as a deeply frozen Ruby Hash, on demand.
    /// Built per call rather than cached, exactly as `Turn#content` is, so the
    /// handle never holds a Ruby reference -- which is what keeps it trivially
    /// shareable.
    fn table_to_ruby(ruby: &Ruby, table: &BTreeMap<String, Setting>) -> Result<Value, Error> {
        let hash = ruby.hash_new();
        table.iter().try_for_each(|(key, value)| {
            hash.aset(frozen_str(ruby, key), setting_to_ruby(ruby, value)?)
        })?;
        hash.freeze();
        Ok(hash.as_value())
    }

    fn setting_to_ruby(ruby: &Ruby, setting: &Setting) -> Result<Value, Error> {
        Ok(match setting {
            Setting::Str(text) => frozen_str(ruby, text),
            Setting::Int(n) => ruby.integer_from_i64(*n).as_value(),
            Setting::Float(f) => ruby.float_from_f64(*f).as_value(),
            Setting::Bool(true) => ruby.qtrue().as_value(),
            Setting::Bool(false) => ruby.qfalse().as_value(),
            Setting::List(items) => {
                let array = ruby.ary_new_capa(items.len());
                items
                    .iter()
                    .try_for_each(|item| array.push(setting_to_ruby(ruby, item)?))?;
                array.freeze();
                array.as_value()
            }
            Setting::Table(table) => table_to_ruby(ruby, table)?,
        })
    }

    // Each pure error type's `Display` IS the Ruby-visible message; there is no
    // second, hand-built wording here to drift away from the Rust tests.
    fn parse_error(ruby: &Ruby, err: &ParseError) -> Error {
        lookup_error(
            ruby,
            &["Lain", "Ext", "Prompt", "ParseError"],
            err.to_string(),
        )
    }

    fn style_error(ruby: &Ruby, err: &StyleError) -> Error {
        lookup_error(
            ruby,
            &["Lain", "Ext", "Prompt", "StyleError"],
            err.to_string(),
        )
    }

    fn config_error(ruby: &Ruby, err: &ConfigError) -> Error {
        lookup_error(
            ruby,
            &["Lain", "Ext", "Prompt", "ConfigError"],
            err.to_string(),
        )
    }

    /// Register `Lain::Ext::Prompt` and its three named errors. Called from
    /// `lib.rs`'s `init`; the class definition lives here so the whole formatter
    /// -- grammar, vocabulary, and binding -- stays in one file.
    pub fn define(ruby: &Ruby, ext: RModule, lain_error: ExceptionClass) -> Result<(), Error> {
        let prompt = ext.define_class("Prompt", ruby.class_object())?;
        prompt.define_error("ParseError", lain_error)?;
        prompt.define_error("StyleError", lain_error)?;
        prompt.define_error("ConfigError", lain_error)?;
        prompt.define_singleton_method("compile", function!(Prompt::compile, 1))?;
        prompt.define_singleton_method("from_toml", function!(Prompt::from_toml, 1))?;
        prompt.define_singleton_method("width", function!(Prompt::width, 1))?;
        prompt.define_method("source", method!(Prompt::source, 0))?;
        prompt.define_method("variables", method!(Prompt::variables, 0))?;
        prompt.define_method("settings", method!(Prompt::settings, 0))?;
        prompt.define_method("render", method!(Prompt::render, -1))?;
        Ok(())
    }
}

# frozen_string_literal: true

RSpec.describe Lain::Structural::Queries do
  # Each capture Hash from Ext::TreeSitter is {"name" => role, "text" => ...}.
  # A query is exercised by compiling it against the pinned grammar and reading
  # back the {role => name} pairs it binds.
  def roles_and_names(language, source)
    query = described_class.fetch(language, :symbols)
    Lain::Ext::TreeSitter.query(source, language.to_s, query)
                         .map { |capture| [capture.fetch("name"), capture.fetch("text")] }
  end

  describe "ruby/symbols.scm" do
    let(:source) do
      <<~RUBY
        module Geometry
          PI = 3.14159

          # class NotReal
          class Circle
            def area
              compute("class AlsoNotReal")
            end

            def self.unit
              new
            end
          end
        end
      RUBY
    end

    it "compiles against the grammar without a BadQuery" do
      expect { described_class.fetch(:ruby, :symbols) }.not_to raise_error
      expect { Lain::Ext::TreeSitter.query("x = 1", "ruby", described_class.fetch(:ruby, :symbols)) }
        .not_to raise_error
    end

    it "captures the module as a namespace definition" do
      expect(roles_and_names(:ruby, source)).to include(["definition.namespace", "Geometry"])
    end

    it "captures the class as a class definition" do
      expect(roles_and_names(:ruby, source)).to include(["definition.class", "Circle"])
    end

    it "captures instance and singleton methods as method definitions" do
      pairs = roles_and_names(:ruby, source)
      expect(pairs).to include(["definition.method", "area"])
      expect(pairs).to include(["definition.method", "unit"])
    end

    it "captures a constant assignment as a constant definition" do
      expect(roles_and_names(:ruby, source)).to include(["definition.constant", "PI"])
    end

    it "captures at least one call reference" do
      expect(roles_and_names(:ruby, source)).to include(["definition.method", "area"])
        .and include(["reference.call", "compute"])
    end

    it "does not capture an identifier that only appears in a comment or string" do
      names = roles_and_names(:ruby, source).map(&:last)
      expect(names).not_to include("NotReal")
      expect(names).not_to include("AlsoNotReal")
    end
  end

  describe "typescript/symbols.scm" do
    let(:source) do
      <<~TS
        // class NotReal
        namespace Shapes {
          export interface Drawable { draw(): void; }
          export enum Kind { Round }

          export class Circle {
            render() {
              return build("class AlsoNotReal");
            }
          }

          export function make(): Circle {
            return new Circle();
          }

          export const scale = (n: number) => n * 2;
          export type Id = string;
        }
      TS
    end

    it "compiles against the grammar without a BadQuery" do
      expect { Lain::Ext::TreeSitter.query("const x = 1;", "typescript", described_class.fetch(:typescript, :symbols)) }
        .not_to raise_error
    end

    it "captures the namespace, class, interface, function, method and type with roles" do
      pairs = roles_and_names(:typescript, source)
      expect(pairs).to include(["definition.namespace", "Shapes"])
      expect(pairs).to include(["definition.class", "Circle"])
      expect(pairs).to include(["definition.interface", "Drawable"])
      expect(pairs).to include(["definition.function", "make"])
      expect(pairs).to include(["definition.method", "render"])
      expect(pairs).to include(["definition.type", "Id"])
      expect(pairs).to include(["definition.class", "Kind"])      # an enum is a nominal type
      expect(pairs).to include(["definition.function", "scale"])  # a `const f = (...) => ...` binding
    end

    it "captures at least one call reference" do
      expect(roles_and_names(:typescript, source)).to include(["reference.call", "build"])
    end

    it "does not capture an identifier that only appears in a comment or string" do
      names = roles_and_names(:typescript, source).map(&:last)
      expect(names).not_to include("NotReal")
      expect(names).not_to include("AlsoNotReal")
    end
  end

  describe "rust/symbols.scm" do
    let(:source) do
      <<~RUST
        // struct NotReal
        mod geo {
            pub struct Point { x: i32 }
            pub enum Color { Red }
            pub trait Draw { fn draw(&self); }
            pub type Id = u64;

            impl Point {
                fn origin() -> Point {
                    make_point("struct AlsoNotReal")
                }
            }

            fn helper() {}
        }
      RUST
    end

    it "compiles against the grammar without a BadQuery" do
      expect { Lain::Ext::TreeSitter.query("fn main() {}", "rust", described_class.fetch(:rust, :symbols)) }
        .not_to raise_error
    end

    it "captures fn definitions with the function role, including a body-less trait signature" do
      pairs = roles_and_names(:rust, source)
      expect(pairs).to include(["definition.function", "origin"])
      expect(pairs).to include(["definition.function", "helper"])
      expect(pairs).to include(["definition.function", "draw"]) # trait-required `fn draw(&self);`
    end

    it "captures struct and enum as class definitions" do
      pairs = roles_and_names(:rust, source)
      expect(pairs).to include(["definition.class", "Point"])
      expect(pairs).to include(["definition.class", "Color"])
    end

    it "captures the module, trait and type alias with roles" do
      pairs = roles_and_names(:rust, source)
      expect(pairs).to include(["definition.namespace", "geo"])
      expect(pairs).to include(["definition.interface", "Draw"])
      expect(pairs).to include(["definition.type", "Id"])
    end

    it "captures a call reference" do
      expect(roles_and_names(:rust, source)).to include(["reference.call", "make_point"])
    end

    it "does not capture an identifier that only appears in a comment or string" do
      names = roles_and_names(:rust, source).map(&:last)
      expect(names).not_to include("NotReal")
      expect(names).not_to include("AlsoNotReal")
    end
  end

  describe "markdown/sections.scm" do
    let(:source) do
      <<~MD
        # Title

        intro

        ## Sub

        ```rust
        # not a heading
        ```
      MD
    end

    def captures(name)
      query = described_class.fetch(:markdown, :sections)
      Lain::Ext::TreeSitter.query(source, "markdown", query).select { |capture| capture.fetch("name") == name }
    end

    it "compiles against the grammar without a BadQuery" do
      expect { Lain::Ext::TreeSitter.query("# T\n", "markdown", described_class.fetch(:markdown, :sections)) }
        .not_to raise_error
    end

    it "captures a section per heading, nested by level" do
      expect(captures("section").size).to eq(2)
    end

    it "captures each ATX heading, so a section can be labelled by its own text" do
      expect(captures("heading").map { |capture| capture.fetch("text") }).to eq(["# Title\n", "## Sub\n"])
    end

    # The whole reason the grammar beats a regex: inside a fence, a `#` line is
    # code_fence_content and opens nothing.
    it "opens no section for a hash inside a fenced code block" do
      expect(captures("heading").map { |capture| capture.fetch("text") }).not_to include(/not a heading/)
    end
  end

  describe ".fetch" do
    it "raises a loud, named error for a language with no authored query" do
      expect { described_class.fetch(:python, :symbols) }
        .to raise_error(described_class::Unsupported, /python/)
    end

    it "raises for an entirely unknown language too" do
      expect { described_class.fetch(:cobol, :symbols) }
        .to raise_error(described_class::Unsupported, /cobol/)
    end

    # The gate is a {language => [query names]} table, not a wider language
    # list: markdown ships sections only, so asking it for symbols is the same
    # user error as asking python for them -- never the Missing that reports a
    # packaging bug.
    it "raises Unsupported for a language that ships a DIFFERENT query" do
      expect { described_class.fetch(:markdown, :symbols) }
        .to raise_error(described_class::Unsupported, /markdown/)
    end

    it "raises Unsupported for a symbols language asked for sections" do
      expect { described_class.fetch(:ruby, :sections) }
        .to raise_error(described_class::Unsupported, /ruby/)
    end

    # "expected one of []" is a refusal that tells the reader nothing. When the
    # LANGUAGE is known, the actionable fact is what it does ship.
    it "names what a known language does ship when asked for a query it has not got" do
      message = begin
        described_class.fetch(:ruby, :bogus)
      rescue described_class::Unsupported => e
        e.message
      end

      expect(message).to include("ruby")
      expect(message).to include("symbols")
      expect(message).not_to include("[]")
    end

    it "names only the languages that ship the query asked for" do
      message = begin
        described_class.fetch(:python, :symbols)
      rescue described_class::Unsupported => e
        e.message
      end

      expect(message).to include("ruby")
      expect(message).not_to include("markdown")
    end

    it "each authored query declares hand-authored-for-lain MIT provenance" do
      # The grammar's own name, which is not always the language moniker:
      # markdown parses through tree-sitter-md.
      { ruby: %i[symbols], typescript: %i[symbols], rust: %i[symbols], markdown: %i[sections] }
        .each do |language, query_names|
          grammar = language == :markdown ? "tree-sitter-md" : "tree-sitter-#{language}"
          query_names.each do |query_name|
            header = described_class.fetch(language, query_name).lines.first(3).join
            expect(header).to include("Hand-authored for lain (MIT)")
            expect(header).to include(grammar)
          end
        end
    end
  end
end

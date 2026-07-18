# frozen_string_literal: true

RSpec.describe Lain::Structural::Queries do
  # Each capture Hash from Ext::TreeSitter is {"name" => role, "text" => ...}.
  # A query is exercised by compiling it against the pinned grammar and reading
  # back the {role => name} pairs it binds.
  def roles_and_names(language, source)
    query = described_class.fetch(language)
    Lain::Ext::TreeSitter.query(source, language.to_s, query)
                         .map { |capture| [capture.fetch("name"), capture.fetch("text")] }
  end

  describe "ruby/symbols.scm" do
    let(:source) do
      <<~RUBY
        module Geometry
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
      expect { described_class.fetch(:ruby) }.not_to raise_error
      expect { Lain::Ext::TreeSitter.query("x = 1", "ruby", described_class.fetch(:ruby)) }
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

          export class Circle {
            render() {
              return build("class AlsoNotReal");
            }
          }

          export function make(): Circle {
            return new Circle();
          }

          export type Id = string;
        }
      TS
    end

    it "compiles against the grammar without a BadQuery" do
      expect { Lain::Ext::TreeSitter.query("const x = 1;", "typescript", described_class.fetch(:typescript)) }
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
      expect { Lain::Ext::TreeSitter.query("fn main() {}", "rust", described_class.fetch(:rust)) }
        .not_to raise_error
    end

    it "captures fn definitions with the function role" do
      pairs = roles_and_names(:rust, source)
      expect(pairs).to include(["definition.function", "origin"])
      expect(pairs).to include(["definition.function", "helper"])
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

  describe ".fetch" do
    it "raises a loud, named error for an unsupported language" do
      expect { described_class.fetch(:python) }
        .to raise_error(described_class::Unsupported, /python/)
    end

    it "raises for an entirely unknown language too" do
      expect { described_class.fetch(:cobol) }
        .to raise_error(described_class::Unsupported, /cobol/)
    end

    it "each authored query declares hand-authored-for-lain MIT provenance" do
      %i[ruby typescript rust].each do |language|
        header = described_class.fetch(language).lines.first(3).join
        expect(header).to match(/Hand-authored for lain \(MIT\)/)
        expect(header).to match(/tree-sitter-#{language}/)
      end
    end
  end
end

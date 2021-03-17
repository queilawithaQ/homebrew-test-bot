# frozen_string_literal: true

module Homebrew
  module Tests
    class TestFormulae < Test
      def initialize(argument, tap:, git:, dry_run:, fail_fast:, verbose:)
        super(tap: tap, git: git, dry_run: dry_run, fail_fast: fail_fast, verbose: verbose)

        @argument = argument
      end

      attr_reader :argument
      attr_accessor :formulae, :added_formulae, :deleted_formulae, :built_formulae, :test_default_formula

      private

      def safe_formula_canonical_name(formula_name, args:)
        Formulary.factory(formula_name).full_name
      rescue TapFormulaUnavailableError => e
        raise if e.tap.installed?

        test "brew", "tap", e.tap.name
        retry unless steps.last.failed?
        onoe e
        puts e.backtrace if args.debug?
      rescue FormulaUnavailableError, TapFormulaAmbiguityError,
             TapFormulaWithOldnameAmbiguityError => e
        onoe e
        puts e.backtrace if args.debug?
      end

      def rev_parse(ref)
        Utils.popen_read(git, "-C", repository, "rev-parse", "--verify", ref).strip
      end

      def current_sha1
        rev_parse("HEAD")
      end

      def diff_formulae(start_revision, end_revision, path, filter)
        return unless tap

        Utils.safe_popen_read(
          git, "-C", repository,
          "diff-tree", "-r", "--name-only", "--diff-filter=#{filter}",
          start_revision, end_revision, "--", path
        ).lines.map do |line|
          file = Pathname.new line.chomp
          next unless tap.formula_file?(file)

          tap.formula_file_to_name(file)
        end.compact
      end

      def skip(formula_name)
        puts Formatter.headline(
          "#{Formatter.warning("SKIPPED")} #{Formatter.identifier(formula_name)}",
          color: :yellow,
        )
      end

      def satisfied_requirements?(formula, spec, dependency = nil)
        f = Formulary.factory(formula.full_name, spec)
        fi = FormulaInstaller.new(f)
        stable_spec = spec == :stable
        fi.build_bottle = stable_spec

        unsatisfied_requirements, = fi.expand_requirements
        return true if unsatisfied_requirements.empty?

        name = formula.full_name
        name += " (#{spec})" unless stable_spec
        name += " (#{dependency} dependency)" if dependency
        skip name
        puts unsatisfied_requirements.values.flatten.map(&:message)
        false
      end

      def cleanup_during!(args:)
        return unless args.cleanup?
        return unless HOMEBREW_CACHE.exist?

        used_percentage = Utils.safe_popen_read("df", HOMEBREW_CACHE.to_s)
                               .lines[1] # HOMEBREW_CACHE
                               .split[4] # used %
                               .to_i
        return if used_percentage < 95

        test_header(:TestFormulae, method: :cleanup_during!)

        FileUtils.chmod_R "u+rw", HOMEBREW_CACHE, force: true
        test "rm", "-rf", HOMEBREW_CACHE.to_s
      end

      def each_formulae(&block)
        changed_formulae_dependents = {}

        Array(@formulae).each do |formula|
          begin
            formula_dependencies =
              Utils.popen_read("brew", "deps", "--full-name",
                               "--include-build",
                               "--include-test", formula)
                   .split("\n")
            # deps can fail if deps are not tapped
            unless $CHILD_STATUS.success?
              Formulary.factory(formula).recursive_dependencies
              # If we haven't got a TapFormulaUnavailableError, then something else is broken
              raise "Failed to determine dependencies for '#{formula}'."
            end
          rescue TapFormulaUnavailableError => e
            raise if e.tap.installed?

            e.tap.clear_cache
            safe_system "brew", "tap", e.tap.name
            retry
          end

          unchanged_dependencies = formula_dependencies - @formulae
          changed_dependencies = formula_dependencies - unchanged_dependencies
          changed_dependencies.each do |changed_formula|
            changed_formulae_dependents[changed_formula] ||= 0
            changed_formulae_dependents[changed_formula] += 1
          end
        end

        changed_formulae = changed_formulae_dependents.sort do |a1, a2|
          a2[1].to_i <=> a1[1].to_i
        end
        changed_formulae.map!(&:first)
        unchanged_formulae = Array(@formulae) - changed_formulae
        changed_formulae + unchanged_formulae

        Array(formulae).each(&block)
      end
    end
  end
end

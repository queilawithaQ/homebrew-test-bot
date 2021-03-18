# frozen_string_literal: true

module Homebrew
  module Tests
    class FormulaeDependents < TestFormulae
      def run!(args:)
        each_formulae.each do |f|
          dependents!(f, args: args)
        end
      end

      def dependents!(formula_name, args:)
        test_header(:FormulaeDependents, method: "dependents!(#{formula_name})")

        @built_formulae ||= []
        @built_formulae << formula_name

        return unless formula_should_be_tested?(formula_name)

        formula = Formulary.factory(formula_name)

        setup_formulae_deps_instances(formula, formula_name, args: args)

        @source_dependents.each do |dependent|
          install_dependent_from_source(dependent, args: args)

          bottled = with_env(HOMEBREW_SKIP_OR_LATER_BOTTLES: "1") do
            dependent.bottled?
          end
          install_bottled_dependent(dependent, args: args) if bottled
        end

        @bottled_dependents.each do |dependent|
          install_bottled_dependent(dependent, args: args)
        end
      end

      private

      def setup_formulae_deps_instances(formula, formula_name, args:)
        # Test reverse dependencies for linux-only formulae in linuxbrew-core.
        if args.keep_old? && formula.requirements.exclude?(LinuxRequirement.new)
          @testable_dependents = @bottled_dependents = @source_dependents = []
          return
        end

        info_header "Determining dependents..."

        build_dependents_from_source_allowlist = %w[
          cabal-install
          docbook-xsl
          erlang
          ghc
          go
          ocaml
          ocaml-findlib
          ocaml-num
          openjdk
          rust
        ]

        uses_args = %w[--formula --include-build --include-test]
        uses_args << "--recursive" unless args.skip_recursive_dependents?
        dependents = with_env(HOMEBREW_STDERR: "1") do
          Utils.safe_popen_read("brew", "uses", *uses_args, formula_name)
               .split("\n")
        end
        dependents -= @formulae
        dependents = dependents.map { |d| Formulary.factory(d) }

        dependents = dependents.zip(dependents.map do |f|
          if args.skip_recursive_dependents?
            f.deps
          else
            begin
              f.recursive_dependencies
            rescue TapFormulaUnavailableError => e
              raise if e.tap.installed?

              e.tap.clear_cache
              safe_system "brew", "tap", e.tap.name
              retry
            end
          end.reject(&:optional?)
        end)

        # Defer formulae which could be tested later
        # i.e. formulae that also depend on something else yet to be built in this test run.
        dependents.select! do |_, deps|
          still_to_test = @formulae - @built_formulae
          (deps.map { |d| d.to_formula.full_name } & still_to_test).empty?
        end

        # Split into dependents that we could potentially be building from source and those
        # we should not. The criteria is that it depends on a formula in the allowlist and
        # that formula has been, or will be, built in this test run.
        @source_dependents, dependents = dependents.partition do |_, deps|
          deps.any? do |d|
            full_name = d.to_formula.full_name

            next false unless build_dependents_from_source_allowlist.include?(full_name)

            @formulae.include?(full_name)
          end
        end

        # From the non-source list, get rid of any dependents we are only a build dependency to
        dependents.select! do |_, deps|
          deps.reject { |d| d.build? && !d.test? }
              .map(&:to_formula)
              .include?(formula)
        end

        dependents = dependents.transpose.first.to_a
        @source_dependents = @source_dependents.transpose.first.to_a

        @testable_dependents = @source_dependents.select(&:test_defined?)
        @bottled_dependents = with_env(HOMEBREW_SKIP_OR_LATER_BOTTLES: "1") do
          dependents.select(&:bottled?)
        end
        @testable_dependents += @bottled_dependents.select(&:test_defined?)
      end

      def unlink_conflicts(formula)
        return if formula.keg_only?
        return if formula.linked_keg.exist?

        conflicts = formula.conflicts.map { |c| Formulary.factory(c.name) }
                           .select(&:any_version_installed?)
        formula_recursive_dependencies = begin
          formula.recursive_dependencies
        rescue TapFormulaUnavailableError => e
          raise if e.tap.installed?

          e.tap.clear_cache
          safe_system "brew", "tap", e.tap.name
          retry
        end
        formula_recursive_dependencies.each do |dependency|
          conflicts += dependency.to_formula.conflicts.map do |c|
            Formulary.factory(c.name)
          end.select(&:any_version_installed?)
        end
        conflicts.each do |conflict|
          test "brew", "unlink", conflict.name
        end
      end

      def install_dependent_from_source(dependent, args:)
        return unless satisfied_requirements?(dependent, :stable)

        if dependent.deprecated? || dependent.disabled?
          verb = dependent.deprecated? ? :deprecated : :disabled
          puts "#{dependent.full_name} has been #{verb}!"
          skip dependent.full_name
          return
        end

        cleanup_during!(args: args)

        unless dependent.latest_version_installed?
          test "brew", "fetch", "--retry", dependent.full_name
          return if steps.last.failed?

          unlink_conflicts dependent

          test "brew", "install", "--build-from-source", "--only-dependencies", dependent.full_name,
               env:  { "HOMEBREW_DEVELOPER" => nil }
          test "brew", "install", "--build-from-source", dependent.full_name,
               env:  { "HOMEBREW_DEVELOPER" => nil }
          return if steps.last.failed?
        end
        return unless dependent.latest_version_installed?

        if !dependent.keg_only? && !dependent.linked_keg.exist?
          unlink_conflicts dependent
          test "brew", "link", dependent.full_name
        end
        test "brew", "install", "--only-dependencies", dependent.full_name
        test "brew", "linkage", "--test", dependent.full_name

        if @testable_dependents.include? dependent
          test "brew", "install", "--only-dependencies", "--include-test",
               dependent.full_name
          test "brew", "test", "--retry", "--verbose", dependent.full_name
        end

        test "brew", "uninstall", "--force", dependent.full_name
      end

      def install_bottled_dependent(dependent, args:)
        return unless satisfied_requirements?(dependent, :stable)

        if dependent.deprecated? || dependent.disabled?
          verb = dependent.deprecated? ? :deprecated : :disabled
          puts "#{dependent.full_name} has been #{verb}!"
          skip dependent.full_name
          return
        end

        cleanup_during!(args: args)

        unless dependent.latest_version_installed?
          test "brew", "fetch", "--retry", dependent.full_name
          return if steps.last.failed?

          unlink_conflicts dependent

          test "brew", "install", "--only-dependencies", dependent.full_name,
               env:  { "HOMEBREW_DEVELOPER" => nil }
          test "brew", "install", dependent.full_name,
               env:  { "HOMEBREW_DEVELOPER" => nil }
          return if steps.last.failed?
        end
        return unless dependent.latest_version_installed?

        if !dependent.keg_only? && !dependent.linked_keg.exist?
          unlink_conflicts dependent
          test "brew", "link", dependent.full_name
        end
        test "brew", "install", "--only-dependencies", dependent.full_name
        test "brew", "linkage", "--test", dependent.full_name

        if @testable_dependents.include? dependent
          test "brew", "install", "--only-dependencies", "--include-test",
               dependent.full_name
          test "brew", "test", "--retry", "--verbose", dependent.full_name
        end

        test "brew", "uninstall", "--force", dependent.full_name
      end
    end
  end
end

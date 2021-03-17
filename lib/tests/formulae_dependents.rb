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

        formula = Formulary.factory(formula_name)
        if formula.disabled?
          ofail "#{formula.full_name} has been disabled!"
          skip formula.name
          return
        end
        new_formula = Array(@added_formulae).include?(formula_name)

        if Hardware::CPU.arm? &&
           ENV["HOMEBREW_REQUIRE_BOTTLED_ARM"] &&
           !formula.bottled? &&
           !formula.bottle_unneeded? &&
           !new_formula
          opoo "#{formula.full_name} has not yet been bottled on ARM!"
          skip formula.name
          return
        end

        if OS.linux? &&
           tap.present? &&
           tap.full_name == "Homebrew/homebrew-core" &&
           ENV["HOMEBREW_REQUIRE_BOTTLED_LINUX"] &&
           !formula.bottled? &&
           !formula.bottle_unneeded?
          opoo "#{formula.full_name} has not yet been bottled on Linux!"
          skip formula.name
          return
        end

        return unless satisfied_requirements?(formula, :stable)

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
      ensure
        cleanup_bottle_etc_var(formula) if args.cleanup?

        test "brew", "uninstall", "--force", *@unchanged_dependencies if @unchanged_dependencies.present?
      end

      private

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
          skip dependent.name
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
          skip dependent.name
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

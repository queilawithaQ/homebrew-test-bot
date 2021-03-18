# frozen_string_literal: true

module Homebrew
  module Tests
    class FormulaeBottle < TestFormulae
      def run!(args:)
        each_formulae do |f|
          bottle!(f, args: args)
        end
        deleted_formulae.each do |f|
          deleted_formula!(f)
        end
      end

      def bottle!(formula_name, args:)
        cleanup_during!(args: args)

        test_header(:FormulaeBottle, method: "bottle!(#{formula_name})")

        return unless formula_should_be_tested?(formula_name)

        formula = Formulary.factory(formula_name)
        new_formula = @added_formulae.include?(formula_name)

        deps = []
        reqs = []

        fetch_args = [formula_name]
        fetch_args << "--build-bottle" if !formula.bottle_disabled? && !args.build_from_source?
        fetch_args << "--force" if args.cleanup?

        livecheck_args = [formula_name]
        livecheck_args << "--full-name"
        livecheck_args << "--debug"

        audit_args = [formula_name, "--online"]
        if new_formula
          audit_args << "--new-formula"
        else
          audit_args << "--git" << "--skip-style"
        end

        unless satisfied_requirements?(formula, :stable)
          fetch_formula(fetch_args, audit_args)
          return
        end

        deps |= formula.deps.to_a.reject(&:optional?)
        reqs |= formula.requirements.to_a.reject(&:optional?)

        tap_needed_taps(deps)

        dep_failed = !install_gcc_if_needed(formula, deps)
        dep_failed ||= !install_mercurial_if_needed(deps, reqs)
        dep_failed ||= !install_subversion_if_needed(deps, reqs)
        if dep_failed
          @skipped_or_failed_formulae << formula_name
          return
        end

        setup_formulae_deps_instances(formula, formula_name)

        info_header "Starting build of #{formula_name}"

        test "brew", "fetch", "--retry", *fetch_args

        test "brew", "uninstall", "--force", formula_name if formula.latest_version_installed?

        install_args = ["--verbose"]
        install_args << "--build-bottle" if !formula.bottle_disabled? && !args.build_from_source?
        install_args << formula_name

        # Don't care about e.g. bottle failures for dependencies.
        test "brew", "install", "--only-dependencies", *install_args,
             env:  { "HOMEBREW_DEVELOPER" => nil }

        test "brew", "install", *install_args,
             env:  { "HOMEBREW_DEVELOPER" => nil }
        install_passed = steps.last.passed?

        test "brew", "livecheck", *livecheck_args if formula.livecheckable? && !formula.livecheck.skip?

        test "brew", "audit", *audit_args unless formula.deprecated?
        unless install_passed
          @skipped_or_failed_formulae << formula_name
          return
        end

        bottle_reinstall_formula(formula, new_formula, args: args)
        test "brew", "linkage", "--test", formula_name
        failed_linkage_or_test = steps.last.failed?

        test "brew", "install", "--only-dependencies", "--include-test", formula_name

        if formula.test_defined?
          # Intentionally not passing --retry here to avoid papering over
          # flaky tests when a formula isn't being pulled in as a dependent.
          test "brew", "test", "--verbose", formula_name
          failed_linkage_or_test ||= steps.last.failed?
        end

        # Move bottle and don't test dependents if the formula linkage or test failed.
        if failed_linkage_or_test
          @skipped_or_failed_formulae << formula_name

          if @bottle_filename
            failed_dir = "#{File.dirname(@bottle_filename)}/failed"
            FileUtils.mkdir failed_dir unless File.directory? failed_dir
            FileUtils.mv [@bottle_filename, @bottle_json_filename], failed_dir
          end
        end
      ensure
        cleanup_bottle_etc_var(formula) if args.cleanup?

        test "brew", "uninstall", "--force", *@unchanged_dependencies if @unchanged_dependencies.present?
      end

      private

      def tap_needed_taps(deps)
        deps.each { |d| d.to_formula.recursive_dependencies }
      rescue TapFormulaUnavailableError => e
        raise if e.tap.installed?

        e.tap.clear_cache
        safe_system "brew", "tap", e.tap.name
        retry
      end

      def fetch_formula(fetch_args, audit_args, spec_args = [])
        test "brew", "fetch", "--retry", *spec_args, *fetch_args
        test "brew", "audit", *audit_args
      end

      def install_gcc_if_needed(formula, deps)
        installed_gcc = false
        begin
          deps.each { |dep| CompilerSelector.select_for(dep.to_formula) }
          CompilerSelector.select_for(formula)
        rescue CompilerSelectionError => e
          unless installed_gcc
            test "brew", "install", "gcc",
                 env: { "HOMEBREW_DEVELOPER" => nil }
            installed_gcc = true
            DevelopmentTools.clear_version_cache
            retry
          end
          skip formula.full_name
          puts e.message
          return false
        end

        true
      end

      def install_mercurial_if_needed(deps, reqs)
        return true if (deps | reqs).none? { |d| d.name == "mercurial" && d.build? }

        test "brew", "install", "mercurial",
             env:  { "HOMEBREW_DEVELOPER" => nil }
        steps.last.passed?
      end

      def install_subversion_if_needed(deps, reqs)
        return true if (deps | reqs).none? { |d| d.name == "subversion" && d.build? }

        test "brew", "install", "subversion",
             env:  { "HOMEBREW_DEVELOPER" => nil }
        steps.last.passed?
      end

      def setup_formulae_deps_instances(formula, formula_name)
        conflicts = formula.conflicts
        formula.recursive_dependencies.each do |dependency|
          conflicts += dependency.to_formula.conflicts
        end
        unlink_formulae = conflicts.map(&:name)
        unlink_formulae.uniq.each do |name|
          unlink_formula = Formulary.factory(name)
          next unless unlink_formula.latest_version_installed?
          next unless unlink_formula.linked_keg.exist?

          test "brew", "unlink", name
        end

        info_header "Determining dependencies..."
        installed = Utils.safe_popen_read("brew", "list", "--formula").split("\n")
        dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-build",
                                "--include-test", formula_name)
               .split("\n")
        installed_dependencies = installed & dependencies
        installed_dependencies.each do |name|
          link_formula = Formulary.factory(name)
          next if link_formula.keg_only?
          next if link_formula.linked_keg.exist?

          test "brew", "link", name
        end

        dependencies -= installed
        @unchanged_dependencies = dependencies - @formulae
        test "brew", "fetch", "--retry", *@unchanged_dependencies unless @unchanged_dependencies.empty?

        changed_dependencies = dependencies - @unchanged_dependencies
        unless changed_dependencies.empty?
          test "brew", "fetch", "--retry", "--build-from-source",
               *changed_dependencies
          # Install changed dependencies as new bottles so we don't have
          # checksum problems.
          test "brew", "install", "--build-from-source", *changed_dependencies
          # Run postinstall on them because the tested formula might depend on
          # this step
          test "brew", "postinstall", *changed_dependencies
        end

        runtime_or_test_dependencies =
          Utils.safe_popen_read("brew", "deps", "--include-test", formula_name)
               .split("\n")
        build_dependencies = dependencies - runtime_or_test_dependencies
        @unchanged_build_dependencies = build_dependencies - @formulae
      end

      def cleanup_bottle_etc_var(formula)
        bottle_prefix = formula.opt_prefix/".bottle"
        # Nuke etc/var to have them be clean to detect bottle etc/var
        # file additions.
        Pathname.glob("#{bottle_prefix}/{etc,var}/**/*").each do |bottle_path|
          prefix_path = bottle_path.sub(bottle_prefix, HOMEBREW_PREFIX)
          FileUtils.rm_rf prefix_path
        end
      end

      def bottle_reinstall_formula(formula, new_formula, args:)
        if formula.bottle_disabled? || args.build_from_source?
          @bottle_filename = nil
          return
        end

        root_url = args.root_url

        # GitHub Releases url
        root_url ||= if tap.present? && !tap.core_tap? && !args.bintray_org && !@test_default_formula
          "#{tap.default_remote}/releases/download/#{formula.name}-#{formula.pkg_version}"
        end

        ENV["HOMEBREW_BOTTLE_SUDO_PURGE"] = "1" if MacOS.version >= :catalina
        bottle_args = ["--verbose", "--json", formula.full_name]
        bottle_args << "--keep-old" if args.keep_old? && !new_formula
        bottle_args << "--skip-relocation" if args.skip_relocation?
        bottle_args << "--force-core-tap" if @test_default_formula
        bottle_args << "--root-url=#{root_url}" if root_url
        bottle_args << "--or-later" if args.or_later?
        test "brew", "bottle", *bottle_args

        bottle_step = steps.last
        return unless bottle_step.passed?
        return unless bottle_step.output?

        @bottle_filename =
          bottle_step.output
                     .gsub(%r{.*(\./\S+#{Utils::Bottles.native_regex}).*}m, '\1')
        @bottle_json_filename =
          @bottle_filename.gsub(/\.(\d+\.)?tar\.gz$/, ".json")
        bottle_merge_args =
          ["--merge", "--write", "--no-commit", @bottle_json_filename]
        bottle_merge_args << "--keep-old" if args.keep_old? && !new_formula

        test "brew", "bottle", *bottle_merge_args
        test "brew", "uninstall", "--force", formula.full_name

        bottle_json = JSON.parse(File.read(@bottle_json_filename))
        root_url = bottle_json.dig(formula.full_name, "bottle", "root_url")
        filename = bottle_json.dig(formula.full_name, "bottle", "tags").values.first["filename"]

        download_strategy = CurlDownloadStrategy.new("#{root_url}/#{filename}", formula.name, formula.version)

        HOMEBREW_CACHE.mkpath
        FileUtils.ln @bottle_filename, download_strategy.cached_location, force: true
        FileUtils.ln_s download_strategy.cached_location.relative_path_from(download_strategy.symlink_location),
                       download_strategy.symlink_location,
                       force: true

        @formulae.delete(formula.name)

        unless @unchanged_build_dependencies.empty?
          test "brew", "uninstall", "--force", *@unchanged_build_dependencies
          @unchanged_dependencies -= @unchanged_build_dependencies
        end

        test "brew", "install", "--only-dependencies", @bottle_filename
        test "brew", "install", @bottle_filename
      end
    end
  end
end

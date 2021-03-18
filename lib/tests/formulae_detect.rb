# frozen_string_literal: true

module Homebrew
  module Tests
    class FormulaeDetect < TestFormulae
      def run!(args:)
        detect_formulae!(args: args)
      end

      def detect_formulae!(args:)
        test_header(:FormulaeDetect, method: :detect_formulae!)

        url = nil
        origin_ref = "origin/master"

        if argument == "HEAD"
          # Use GitHub Actions variables for pull request jobs.
          if ENV["GITHUB_REF"].present? && ENV["GITHUB_REPOSITORY"].present? &&
             %r{refs/pull/(?<pr>\d+)/merge} =~ ENV["GITHUB_REF"]
            url = "https://github.com/#{ENV["GITHUB_REPOSITORY"]}/pull/#{pr}/checks"
          end
        elsif (canonical_formula_name = safe_formula_canonical_name(argument, args: args))
          @formulae = [canonical_formula_name]
        else
          raise UsageError,
                "#{argument} is not detected from GitHub Actions or a formula name!"
        end

        if ENV["GITHUB_REPOSITORY"].blank? || ENV["GITHUB_SHA"].blank? || ENV["GITHUB_REF"].blank?
          if ENV["GITHUB_ACTIONS"]
            odie <<~EOS
              We cannot find the needed GitHub Actions environment variables! Check you have e.g. exported them to a Docker container.
            EOS
          elsif ENV["CI"]
            onoe <<~EOS
              No known CI provider detected! If you are using GitHub Actions then we cannot find the expected environment variables! Check you have e.g. exported them to a Docker container.
            EOS
          end
        elsif tap.present? && tap.full_name.casecmp(ENV["GITHUB_REPOSITORY"]).zero?
          # Use GitHub Actions variables for pull request jobs.
          if ENV["GITHUB_BASE_REF"].present?
            test git, "-C", repository, "fetch",
                 "origin", "+refs/heads/#{ENV["GITHUB_BASE_REF"]}"
            origin_ref = "origin/#{ENV["GITHUB_BASE_REF"]}"
            diff_start_sha1 = rev_parse(origin_ref)
            diff_end_sha1 = ENV["GITHUB_SHA"]
          # Use GitHub Actions variables for branch jobs.
          else
            test git, "-C", repository, "fetch", "origin", "+#{ENV["GITHUB_REF"]}"
            origin_ref = "origin/#{ENV["GITHUB_REF"].gsub(%r{^refs/heads/}, "")}"
            diff_end_sha1 = diff_start_sha1 = ENV["GITHUB_SHA"]
          end
        end

        if diff_start_sha1.present? && diff_end_sha1.present?
          merge_base_sha1 =
            Utils.safe_popen_read(git, "-C", repository, "merge-base",
                                  diff_start_sha1, diff_end_sha1).strip
          diff_start_sha1 = merge_base_sha1 if merge_base_sha1.present?
        end

        diff_start_sha1 = current_sha1 if diff_start_sha1.blank?
        diff_end_sha1 = current_sha1 if diff_end_sha1.blank?

        diff_start_sha1 = diff_end_sha1 if formulae.present?

        if tap
          tap_origin_ref_revision_args =
            [git, "-C", tap.path.to_s, "log", "-1", "--format=%h (%s)", origin_ref]
          tap_origin_ref_revision = if args.dry_run?
            # May fail on dry run as we've not fetched.
            Utils.popen_read(*tap_origin_ref_revision_args).strip
          else
            Utils.safe_popen_read(*tap_origin_ref_revision_args)
          end.strip
          tap_revision = Utils.safe_popen_read(
            git, "-C", tap.path.to_s,
            "log", "-1", "--format=%h (%s)"
          ).strip
        end

        puts <<-EOS
    url             #{url.presence || "(undefined)"}
    #{origin_ref}   #{tap_origin_ref_revision.presence || "(undefined)"}
    HEAD            #{tap_revision.presence || "(undefined)"}
    diff_start_sha1 #{diff_start_sha1.presence || "(undefined)"}
    diff_end_sha1   #{diff_end_sha1.presence || "(undefined)"}
        EOS

        modified_formulae = []

        if tap && diff_start_sha1 != diff_end_sha1
          formula_path = tap.formula_dir.to_s
          @added_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "A")
          modified_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "M")
          @deleted_formulae +=
            diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "D")
        end

        # Build the default test formula.
        modified_formulae << "testbottest" if @test_default_formula

        @formulae += @added_formulae + modified_formulae

        if formulae.blank? && deleted_formulae.blank? && diff_start_sha1 == diff_end_sha1
          raise UsageError, "Did not find any formulae or commits to test!"
        end

        info_header "Testing Formula changes:"
        puts <<-EOS
    added    #{@added_formulae.blank?    ? "(empty)" : @added_formulae.join(" ")}
    modified #{modified_formulae.blank?  ? "(empty)" : modified_formulae.join(" ")}
    deleted  #{@deleted_formulae.blank?  ? "(empty)" : @deleted_formulae.join(" ")}
        EOS
      end
    end
  end
end

# frozen_string_literal: true

require "cli/parser"
module Homebrew
  module_function

  def test_bot_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `test-bot` [<options>] [<formula>]

        Tests the full lifecycle of a Homebrew change to a tap (Git repository). For example, for a GitHub Actions pull request that changes a formula `brew test-bot` will ensure the system is cleaned and set up to test the formula, install the formula, run various tests and checks on it, bottle (package) the binaries and test formulae that depend on it to ensure they aren't broken by these changes.

        Only supports GitHub Actions as a CI provider. This is because Homebrew uses GitHub Actions and it's freely available for public and private use with macOS and Linux workers.
      EOS

      switch "--dry-run",
             description: "Print what would be done rather than doing it."
      switch "--cleanup",
             description: "Clean all state from the Homebrew directory. Use with care!"
      switch "--skip-setup",
             description: "Don't check if the local system is set up correctly."
      switch "--build-from-source",
             description: "Build from source rather than building bottles."
      switch "--keep-old",
             description: "Run `brew bottle --keep-old` to build new bottles for a single platform."
      switch "--skip-relocation",
             description: "Run `brew bottle --skip-relocation` to build new bottles that don't require relocation."
      switch "--local",
             description: "Ask Homebrew to write verbose logs under `./logs/` and set `$HOME` to `./home/`"
      flag   "--tap=",
             description: "Use the Git repository of the given tap. Defaults to the core tap for syntax checking."
      switch "--fail-fast",
             description: "Immediately exit on a failing step."
      switch "-v", "--verbose",
             description: "Print test step output in real time. Has the side effect of " \
                          "passing output as raw bytes instead of re-encoding in UTF-8."
      switch "--test-default-formula",
             description: "Use a default testing formula when not building a tap and no other formulae are specified."
      flag   "--bintray-org=",
             description: "Upload bottles to the given Bintray organisation."
      flag   "--root-url=",
             description: "Use the specified <URL> as the root of the bottle's URL instead of Homebrew's default."
      flag   "--git-name=",
             description: "Set the Git author/committer names to the given name."
      flag   "--git-email=",
             description: "Set the Git author/committer email to the given email."
      switch "--ci-upload",
             description: "Use the Homebrew CI bottle upload options."
      switch "--publish",
             description: "Publish the uploaded bottles."
      switch "--skip-recursive-dependents",
             description: "Only test the direct dependents."
      switch "--only-cleanup-before",
             description: "Only run the pre-cleanup step. Needs `--cleanup`."
      switch "--only-setup",
             description: "Only run the local system setup check step."
      switch "--only-tap-syntax",
             description: "Only run the tap syntax check step."
      switch "--only-formulae",
             description: "Only run the formulae steps."
      switch "--only-formulae-bottle",
             description: "Only run the formulae bottle step."
      switch "--only-formulae-dependents",
             description: "Only run the formulae dependents step."
      switch "--only-cleanup-after",
             description: "Only run the post-cleanup step. Needs `--cleanup`."
      conflicts "--only-cleanup-before", "--only-setup", "--only-tap-syntax",
                "--only-formulae", "--only-cleanup-after"
    end
  end

  def test_bot
    setup_argv_and_env

    args = test_bot_args.parse

    # Keep this after the .parse to keep --help fast.
    require_relative "../lib/test_bot"

    Homebrew::TestBot.run!(args)
  end

  def setup_argv_and_env
    github_actions = ENV["GITHUB_ACTIONS"].present?
    if github_actions
      ARGV << "--cleanup"
      ENV["HOMEBREW_COLOR"] = "1"
      ENV["HOMEBREW_GITHUB_ACTIONS"] = "1"
    end

    ARGV << "--local" if ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"].present?
    ARGV << "--verbose" if ARGV.include?("--ci-upload")
  end
end

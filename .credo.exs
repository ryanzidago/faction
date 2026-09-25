%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{included: ["lib/", "test/", "config/", "mix.exs"]},
      plugins: [
        {Bylaw.Credo.Plugin.DisableForNextDefinition, []}
      ],
      checks: %{
        # A long cond or case often reads better than helpers split off to satisfy a count.
        disabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []}
        ],
        extra: [
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.WithSingleClause, []},
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Bylaw.Credo.Check.Elixir.FilterRejectFirst, []},
          {Bylaw.Credo.Check.Elixir.FloatUsage, []},
          {Bylaw.Credo.Check.Elixir.FullySpecifiedStructTypes, []},
          {Bylaw.Credo.Check.Elixir.FullyTypedOpts, []},
          {Bylaw.Credo.Check.Elixir.NamedSpecParams, []},
          {Bylaw.Credo.Check.Elixir.NoParamExtractionInFunctionHead, []},
          {Bylaw.Credo.Check.Elixir.NoThen, []},
          {Bylaw.Credo.Check.Elixir.PreferBlockIf, []},
          {Bylaw.Credo.Check.Elixir.PreferEnumCount, []},
          {Bylaw.Credo.Check.Elixir.PreferEnumUniqBy, []},
          {Bylaw.Credo.Check.Elixir.RejectCount, []},
          {Bylaw.Credo.Check.Elixir.DocBeforeSpec, []},
          {Bylaw.Credo.Check.Elixir.NoRemoteCallsInModuleAttributes, []},
          {Bylaw.Credo.Check.Elixir.PreferEmptyListChecks, []},
          {Bylaw.Credo.Check.Elixir.PreferListTypeSyntax, []},
          {Bylaw.Credo.Check.Testing.NoDescribeBlocks, []},
          {Bylaw.Credo.Check.Testing.NoGlobalStateInTests, []},
          {Bylaw.Credo.Check.Testing.NoSetupInTests, []},
          {Bylaw.Credo.Check.Testing.NoSleepInTests, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MixEnv, [excluded_paths: ["lib/mix/tasks"]]},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []}
        ]
      }
    }
  ]
}

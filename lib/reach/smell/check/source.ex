defmodule Reach.Smell.Check.Source do
  @moduledoc "Macro DSL for source-backed smell checks."

  defmacro __using__(_opts) do
    quote do
      @behaviour Reach.Smell.Check
      @before_compile Reach.Smell.Check.Source

      import ExAST.Sigil
      import ExAST.Query
      import Reach.Smell.Check.Source, only: [smell: 3, smell: 4]

      alias Reach.Smell.SourceRunner

      @pattern_check_source __ENV__.file

      Module.register_attribute(__MODULE__, :smell_patterns, accumulate: true)
      Module.register_attribute(__MODULE__, :smell_query_names, accumulate: true)
      Module.register_attribute(__MODULE__, :smell_ast_callbacks, accumulate: true)

      @impl true
      def run(project) do
        SourceRunner.run(project, [__MODULE__])
      end

      defoverridable run: 1
    end
  end

  defmacro smell(pattern, kind, message) do
    build_smell(pattern, kind, message, [], __CALLER__)
  end

  defmacro smell(pattern, kind, message, opts) do
    build_smell(pattern, kind, message, opts, __CALLER__)
  end

  defp build_smell(pattern, kind, message, opts, caller) do
    prefilter = Keyword.get(opts, :prefilter, :auto)
    remediation_safety = Keyword.get(opts, :remediation_safety, :review_only)
    mode = Keyword.get(opts, :mode, :auto)

    unless remediation_safety in [:equivalent, :conditional, :review_only] do
      raise ArgumentError,
            "remediation_safety must be :equivalent, :conditional, or :review_only"
    end

    if mode == :ast do
      quote do
        @smell_ast_callbacks {unquote(pattern), unquote(kind), unquote(message),
                              unquote(prefilter), unquote(remediation_safety)}
      end
    else
      build_pattern_smell(pattern, kind, message, prefilter, remediation_safety, caller)
    end
  end

  defp build_pattern_smell(pattern, kind, message, prefilter, remediation_safety, caller) do
    if selector_ast?(pattern) do
      idx = Module.get_attribute(caller.module, :smell_query_counter) || 0
      Module.put_attribute(caller.module, :smell_query_counter, idx + 1)
      fun_name = :"__smell_query_#{idx}__"

      quote do
        @smell_query_names {unquote(fun_name), unquote(kind), unquote(message),
                            unquote(prefilter), unquote(remediation_safety)}
        @doc false
        @dialyzer {:nowarn_function, [{unquote(fun_name), 0}]}
        def unquote(fun_name)(), do: unquote(pattern)
      end
    else
      quote do
        @smell_patterns {unquote(pattern), unquote(kind), unquote(message), unquote(prefilter),
                         unquote(remediation_safety)}
      end
    end
  end

  defp selector_ast?({:|>, _, [left, _]}), do: selector_ast?(left)
  defp selector_ast?({:from, _, _}), do: true
  defp selector_ast?(_), do: false

  defmacro __before_compile__(env) do
    ast_callbacks = Module.get_attribute(env.module, :smell_ast_callbacks) || []

    ast_matchers =
      for {callback, _kind, _message, _prefilter, _remediation_safety} <- ast_callbacks do
        quote do
          def __reach_ast_smell_match__(unquote(callback), node), do: unquote(callback)(node)
        end
      end

    quote do
      def __reach_ast_smells__ do
        @smell_ast_callbacks
      end

      unquote_splicing(ast_matchers)

      def __reach_ast_smell_match__(_callback, _node), do: nil

      def __reach_pattern_check__ do
        %{
          source: @pattern_check_source,
          patterns: @smell_patterns,
          queries: @smell_query_names
        }
      end
    end
  end
end

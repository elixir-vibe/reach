defmodule Reach.Effects.Classification do
  @moduledoc """
  Explains an effect classification and where it came from.

  `Reach.Effects.classify/2` remains the compact atom-returning API. Use
  `Reach.Effects.classify_with_provenance/2` when callers need to distinguish
  explicit semantics from typespec or project-local inference.
  """

  @type source ::
          :intrinsic
          | :plugin
          | :local_inference
          | :dependency_inference
          | :builtin
          | :typespec
          | :inferred_type
          | :unknown

  @type confidence :: :high | :medium | :low

  @type reason ::
          :dynamic_dispatch
          | :unresolved_local
          | :unresolved_module
          | :insufficient_semantics
          | :unsupported_call
          | :unsupported_node

  @type t :: %__MODULE__{
          effect: Reach.Effects.effect(),
          source: source(),
          confidence: confidence(),
          classifier: module() | nil,
          reason: reason() | nil
        }

  @enforce_keys [:effect, :source, :confidence]
  defstruct [:effect, :source, :confidence, :classifier, :reason]

  @spec new(Reach.Effects.effect(), source(), confidence(), keyword()) :: t()
  def new(effect, source, confidence, opts \\ []) do
    %__MODULE__{
      effect: effect,
      source: source,
      confidence: confidence,
      classifier: Keyword.get(opts, :classifier),
      reason: Keyword.get(opts, :reason)
    }
  end
end

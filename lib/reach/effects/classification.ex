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
          | :builtin
          | :typespec
          | :inferred_type
          | :unknown

  @type confidence :: :high | :medium | :low

  @type t :: %__MODULE__{
          effect: Reach.Effects.effect(),
          source: source(),
          confidence: confidence(),
          classifier: module() | nil
        }

  @enforce_keys [:effect, :source, :confidence]
  defstruct [:effect, :source, :confidence, :classifier]

  @spec new(Reach.Effects.effect(), source(), confidence(), keyword()) :: t()
  def new(effect, source, confidence, opts \\ []) do
    %__MODULE__{
      effect: effect,
      source: source,
      confidence: confidence,
      classifier: Keyword.get(opts, :classifier)
    }
  end
end

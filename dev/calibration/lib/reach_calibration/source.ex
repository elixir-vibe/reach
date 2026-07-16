defmodule ReachCalibration.Source do
  @moduledoc "Source-selection and snapshot-hydration contract for corpus calibration."

  @callback package_versions(keyword()) ::
              {:ok, ReachCalibration.Selection.t()} | {:error, term()}
  @callback hydrate(map(), keyword()) :: {:ok, map()} | {:error, term()}
end

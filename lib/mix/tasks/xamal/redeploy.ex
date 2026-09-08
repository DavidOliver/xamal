defmodule Mix.Tasks.Xamal.Redeploy do
  @moduledoc "Builds, distributes, and boots the release, without pruning old releases afterward (unlike mix xamal.deploy)."
  @shortdoc "Deploys without pruning old releases"
  use Xamal.MixTask, run: {Xamal.Deployment, :redeploy}
end

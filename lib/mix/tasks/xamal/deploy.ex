defmodule Mix.Tasks.Xamal.Deploy do
  @moduledoc "Builds, distributes, and boots the release, then prunes old releases (see mix xamal.redeploy to skip that)."
  @shortdoc "Deploys the release"
  use Xamal.MixTask, run: {Xamal.Deployment, :deploy}
end

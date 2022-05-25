{
  inputs = {
    dream2nix.url = "github:nix-community/dream2nix";
  };

  outputs = {
    self,
    dream2nix,
  } @ inp: let
    dream2nix = inp.dream2nix.lib2.init {
      systems = ["x86_64-linux"];
      config.projectRoot = ./.;
      config.extra = {
        subsystems.nodejs = {
          builders.node2nix = import "${inp.dream2nix}/src/subsystems/nodejs/builders/node2nix";
          translators.package-json = import "${inp.dream2nix}/src/subsystems/nodejs/translators/package-json";
          discoverers.default = import "${inp.dream2nix}/src/subsystems/nodejs/discoverers/default";
        };
        fetchers.npm = import "${inp.dream2nix}/src/fetchers/npm";
      };
    };
  in
    (dream2nix.makeFlakeOutputs {
      source = ./.;
      # settings = [
      # ];
    })
    // {
      checks = self.packages;
    };
}

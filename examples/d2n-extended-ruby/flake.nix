{
  inputs = {
    dream2nix.url = "github:nix-community/dream2nix";
    src.url = "github:hanami/cli";
    src.flake = false;
  };

  outputs = {
    self,
    dream2nix,
    src,
  } @ inp: let
    dream2nix = inp.dream2nix.lib2.init {
      systems = ["x86_64-linux"];
      config.projectRoot = ./.;
      config.extra = {
        subsystems.ruby = {
          # builders.nixpkgs = import ./subsystem/builder.nix;
          translators.bundler-impure = import ./subsystem/translator.nix;
          discoverers.default = import ./subsystem/discoverer.nix;
        };
        fetchers.rubygems = import ./subsystem/fetcher.nix;
      };
    };
  in
    (dream2nix.makeFlakeOutputs {
      source = src;
      settings = [
      ];
    })
    // {
      # checks.x86_64-linux.hanami-cli = self.packages.x86_64-linux.hanami-cli;
    };
}

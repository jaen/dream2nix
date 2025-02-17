{
  dlib,
  lib,
}: let
  l = lib // builtins;
in {
  generateUnitTestsForProjects = [
    (builtins.fetchTarball {
      url = "https://github.com/BurntSushi/ripgrep/tarball/30ee6f08ee8e22c42ab2ef837c764f52656d025b";
      sha256 = "1g73qfc6wm7d70pksmbzq714mwycdfx1n4vfrivjs7jpkj40q4vv";
    })
  ];

  translate = {translatorName, ...}: {
    project,
    tree,
    packageName,
    ...
  } @ args: let
    # get the root source and project source
    rootSource = tree.fullPath;
    projectSource = "${tree.fullPath}/${project.relPath}";
    projectTree = tree.getNodeFromPath project.relPath;
    subsystemInfo = project.subsystemInfo;

    # Get the root toml
    rootToml = {
      relPath = "";
      value = projectTree.files."Cargo.toml".tomlContent;
    };

    # Get all workspace members
    workspaceMembers =
      l.flatten
      (l.map
        (
          memberName: let
            components = l.splitString "/" memberName;
          in
            # Resolve globs if there are any
            if l.last components == "*"
            then let
              parentDirRel = l.concatStringsSep "/" (l.init components);
              parentDir = "${projectSource}/${parentDirRel}";
              dirs = (projectTree.getNodeFromPath parentDirRel).directories;
            in
              l.mapAttrsToList
              (name: _: "${parentDirRel}/${name}")
              dirs
            else memberName
        )
        (rootToml.value.workspace.members or []));
    # Get cargo packages (for workspace members)
    workspaceCargoPackages =
      l.map
      (relPath: {
        inherit relPath;
        value = (projectTree.getNodeFromPath "${relPath}/Cargo.toml").tomlContent;
      })
      # Filter root referencing member, we already parsed this (rootToml)
      (l.filter (relPath: relPath != ".") workspaceMembers);

    # All cargo packages that we will output
    cargoPackages =
      if l.hasAttrByPath ["package" "name"] rootToml.value
      # Note: the ordering is important here, since packageToml assumes
      # the rootToml to be at 0 index (if it is a package)
      then [rootToml] ++ workspaceCargoPackages
      else workspaceCargoPackages;

    # Get a "main" package toml
    packageToml = l.elemAt cargoPackages 0;

    # Figure out a package name
    packageName =
      if args.packageName == "{automatic}"
      then packageToml.value.package.name
      else args.packageName;

    # Parse Cargo.lock and extract dependencies
    parsedLock = projectTree.files."Cargo.lock".tomlContent;
    parsedDeps = parsedLock.package;
    # This parses a "package-name version" entry in the "dependencies"
    # field of a dependency in Cargo.lock
    makeDepNameVersion = entry: let
      parsed = l.splitString " " entry;
      name = l.head parsed;
      maybeVersion =
        if l.length parsed > 1
        then l.last parsed
        else null;
    in {
      inherit name;
      version =
        # If there is no version, search through the lockfile to
        # find the dependency's version
        if maybeVersion != null
        then maybeVersion
        else
          (
            l.findFirst
            (dep: dep.name == name)
            (throw "no dependency found with name ${name} in Cargo.lock")
            parsedDeps
          )
          .version;
    };

    package = rec {
      toml = packageToml.value;
      name = toml.package.name;
      version =
        toml.package.version
        or (l.warn "no version found in Cargo.toml for ${name}, defaulting to unknown" "unknown");
    };

    # Parses a git source, taken straight from nixpkgs.
    parseGitSource = src: let
      parts = builtins.match ''git\+([^?]+)(\?(rev|tag|branch)=(.*))?#(.*)'' src;
      type = builtins.elemAt parts 2; # rev, tag or branch
      value = builtins.elemAt parts 3;
    in
      if parts == null
      then null
      else
        {
          url = builtins.elemAt parts 0;
          sha = builtins.elemAt parts 4;
        }
        // (lib.optionalAttrs (type != null) {inherit type value;});

    # Extracts a source type from a dependency.
    getSourceTypeFrom = dependencyObject: let
      checkType = type: l.hasPrefix "${type}+" dependencyObject.source;
    in
      if !(l.hasAttr "source" dependencyObject)
      then "path"
      else if checkType "git"
      then "git"
      else if checkType "registry"
      then
        if dependencyObject.source == "registry+https://github.com/rust-lang/crates.io-index"
        then "crates-io"
        else throw "registries other than crates.io are not supported yet"
      else throw "unknown or unsupported source type: ${dependencyObject.source}";
  in
    dlib.simpleTranslate2
    ({...}: rec {
      inherit translatorName;

      # relative path of the project within the source tree.
      location = project.relPath;

      # the name of the subsystem
      subsystemName = "rust";

      # Extract subsystem specific attributes.
      # The structure of this should be defined in:
      #   ./src/specifications/{subsystem}
      subsystemAttrs = rec {
        relPathReplacements = let
          # Extract dependencies from the Cargo.toml of the
          # package we are currently building
          tomlDeps =
            l.flatten
            (
              l.map
              (
                target:
                  (l.attrValues (target.dependencies or {}))
                  ++ (l.attrValues (target.buildDependencies or {}))
              )
              ([package.toml] ++ (l.attrValues (package.toml.target or {})))
            );
          # We only need to patch path dependencies
          pathDeps = l.filter (dep: dep ? path) tomlDeps;
        in
          l.listToAttrs (
            l.map
            (
              dep: {
                name = dep.path;
                value = dlib.sanitizePath "${projectSource}/${dep.path}";
              }
            )
            pathDeps
          );
        gitSources = let
          gitDeps = l.filter (dep: (getSourceTypeFrom dep) == "git") parsedDeps;
        in
          l.unique (l.map (dep: parseGitSource dep.source) gitDeps);
      };

      defaultPackage = package.name;

      /*
       List the package candidates which should be exposed to the user.
       Only top-level packages should be listed here.
       Users will not be interested in all individual dependencies.
       */
      exportedPackages =
        l.foldl
        (acc: el: acc // {"${el.value.package.name}" = el.value.package.version;})
        {}
        cargoPackages;

      /*
       a list of raw package objects
       If the upstream format is a deep attrset, this list should contain
       a flattened representation of all entries.
       */
      serializedRawObjects = parsedDeps;

      /*
       Define extractor functions which each extract one property from
       a given raw object.
       (Each rawObj comes from serializedRawObjects).
       
       Extractors can access the fields extracted by other extractors
       by accessing finalObj.
       */
      extractors = {
        name = rawObj: finalObj: rawObj.name;

        version = rawObj: finalObj: rawObj.version;

        dependencies = rawObj: finalObj:
          l.map makeDepNameVersion (rawObj.dependencies or []);

        sourceSpec = rawObj: finalObj: let
          sourceType = getSourceTypeFrom rawObj;
          sourceConstructors = {
            path = dependencyObject: let
              findCrate =
                l.findFirst
                (
                  crate:
                    (crate.name == dependencyObject.name)
                    && (crate.version == dependencyObject.version)
                )
                null;
              workspaceCrates =
                l.map
                (
                  pkg: rec {
                    inherit (pkg.value.package) name version;
                    inherit (pkg) relPath;
                  }
                )
                cargoPackages;
              workspaceCrate = findCrate workspaceCrates;
              nonWorkspaceCrate = findCrate (subsystemInfo.crates or []);
            in
              if
                (package.name == dependencyObject.name)
                && (package.version == dependencyObject.version)
              then
                dlib.construct.pathSource {
                  path = projectSource;
                  rootName = null;
                  rootVersion = null;
                }
              else if workspaceCrate != null
              then
                dlib.construct.pathSource {
                  path = workspaceCrate.relPath;
                  rootName = package.name;
                  rootVersion = package.version;
                }
              else if nonWorkspaceCrate != null
              then
                dlib.construct.pathSource {
                  path = dlib.sanitizePath "${rootSource}/${nonWorkspaceCrate.relPath}";
                  rootName = null;
                  rootVersion = null;
                }
              else throw "could not find crate '${dependencyObject.name}-${dependencyObject.version}'";

            git = dependencyObject: let
              parsed = parseGitSource dependencyObject.source;
            in {
              type = "git";
              url = parsed.url;
              rev = parsed.sha;
            };

            crates-io = dependencyObject: {
              type = "crates-io";
              name = dependencyObject.name;
              version = dependencyObject.version;
              hash = dependencyObject.checksum;
            };
          };
        in
          sourceConstructors."${sourceType}" rawObj;
      };
    });

  version = 2;

  # If the translator requires additional arguments, specify them here.
  # When users run the CLI, they will be asked to specify these arguments.
  # There are only two types of arguments:
  #   - string argument (type = "argument")
  #   - boolean flag (type = "flag")
  # String arguments contain a default value and examples. Flags do not.
  extraArgs = {
    packageName = {
      description = "name of the package you want to build";
      default = "{automatic}";
      examples = ["rand"];
      type = "argument";
    };
  };
}

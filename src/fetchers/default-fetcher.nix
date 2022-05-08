{
  lib,
  # dream2nix attributes
  dlib,
  fetchSource,
  fetchers,
  ...
}: {
  # sources attrset from dream lock
  defaultPackage,
  defaultPackageVersion,
  sourceOverrides,
  sources,
  ...
}: let
  l = lib // builtins;

  fetchedSources =
    l.mapAttrs
    (name: versions:
      l.mapAttrs
      (version: source:
        if source.type == "unknown"
        then "unknown"
        else if source.type == "path"
        then
          if l.isStorePath (l.concatStringsSep "/" (l.take 4 (l.splitString "/" source.path)))
          then source.path
          else if l.isStorePath (config.rootPath + source.path)
          then config.rootPath + source.path
          else if name == source.rootName && version == source.rootVersion
          then throw "source for ${name}@${version} is referencing itself"
          else "${overriddenSources."${source.rootName}"."${source.rootVersion}"}/${source.path}"
        else if fetchers.fetchers ? "${source.type}"
        then
          fetchSource {
            source =
              source
              // {
                pname = name;
                inherit version;
              };
          }
        else throw "unsupported source type '${source.type}'")
      versions)
    sources;

  overriddenSources =
    l.zipAttrsWith
    (name: versionsSets:
      l.zipAttrsWith
      (version: sources: l.last sources)
      versionsSets)
    [
      fetchedSources
      (sourceOverrides fetchedSources)
    ];
in {
  # attrset: pname -> path of downloaded source
  fetchedSources = overriddenSources;
}

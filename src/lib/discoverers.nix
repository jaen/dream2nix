{
  config,
  dlib,
  lib,
}: let
  l = lib // builtins;

  allDiscoverers = dlib.modules.collectSubsystemModules modules.modules;

  discoverProjects = {
    source ? throw "Pass either `source` or `tree` to discoverProjects",
    tree ? dlib.prepareSourceTree {inherit source;},
    settings ? [],
  }: let
    discoveredProjects =
      l.flatten
      (l.map
        (discoverer: discoverer.discover {inherit tree;})
        allDiscoverers);

    discoveredProjectsSorted = let
      toposorted =
        l.toposort
        (p1: p2: l.hasPrefix p1.relPath p2.relPath)
        discoveredProjects;
      # (lib.traceVal discoveredProjects);
    in
      toposorted.result;
    # (lib.traceValFn (x: "sorted: ${builtins.toJSON x}") toposorted.result);

    # rootProject = lib.traceValFn (x: "rootProject: ${builtins.toJSON x}") (l.head discoveredProjectsSorted);
    rootProject = l.head discoveredProjectsSorted;

    projectsExtended =
      l.forEach discoveredProjectsSorted
      (proj:
        proj
        // {
          translator = l.head proj.translators;
          dreamLockPath = getDreamLockPath proj rootProject;
        });
  in
    # applyProjectSettings projectsExtended settings;
    lib.traceValFn (x: "FINAL RESULT: ${builtins.toJSON x}") (applyProjectSettings projectsExtended settings);

  getDreamLockPath = project: rootProject: let
    root =
      if config.projectRoot == null
      then "."
      else config.projectRoot;
  in
    dlib.sanitizeRelativePath
    "${config.packagesDir}/${rootProject.name}/${project.relPath}/dream-lock.json";

  applyProjectSettings = projects: settingsList: let
    settingsListForProject = project:
      l.filter
      (settings:
        if ! settings ? filter
        then true
        else settings.filter project)
      settingsList;

    applySettings = project: settings:
      l.recursiveUpdate project settings;

    applyAllSettings = project:
      l.foldl'
      (proj: settings: applySettings proj settings)
      project
      (settingsListForProject project);

    settingsApplied =
      l.forEach projects
      (proj: applyAllSettings proj);
  in
    settingsApplied;

  # TODO
  validator = module: true;

  modules = dlib.modules.makeSubsystemModules {
    modulesCategory = "discoverers";
    inherit validator;
  };
in {
  inherit
    applyProjectSettings
    discoverProjects
    ;

  discoverers = modules.modules;
  callDiscoverer = modules.callModule;
  mapDiscoverers = modules.mapModules;
}

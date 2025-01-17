{ lib, config, ... }:
with lib;
let
  inherit (lib.nixvim) mkPluginPackageOption mkSettingsOption toSnakeCase;
in
rec {
  mkExtension =
    {
      name,
      defaultPackage,
      extensionName ? name,
      settingsOptions ? { },
      settingsExample ? null,
      extraOptions ? { },
      imports ? [ ],
      optionsRenamedToSettings ? [ ],
      extraConfig ? cfg: { },
    }:
    {
      # TODO remove this once all deprecation warnings will have been removed.
      imports =
        let
          basePluginPath = [
            "plugins"
            "telescope"
            "extensions"
            name
          ];
          settingsPath = basePluginPath ++ [ "settings" ];
        in
        imports
        ++ (map (
          option:
          let
            optionPath = if isString option then [ option ] else option; # option is already a path (i.e. a list)

            optionPathSnakeCase = map toSnakeCase optionPath;
          in
          mkRenamedOptionModule (basePluginPath ++ optionPath) (settingsPath ++ optionPathSnakeCase)
        ) optionsRenamedToSettings);

      options.plugins.telescope.extensions.${name} = {
        enable = mkEnableOption "the `${name}` telescope extension";

        package = mkPluginPackageOption name defaultPackage;

        settings = mkSettingsOption {
          description = "settings for the `${name}` telescope extension.";
          options = settingsOptions;
          example = settingsExample;
        };
      } // extraOptions;

      config =
        let
          cfg = config.plugins.telescope.extensions.${name};
        in
        mkIf cfg.enable (mkMerge [
          {
            extraPlugins = [ cfg.package ];

            plugins.telescope = {
              enabledExtensions = [ extensionName ];
              settings.extensions.${extensionName} = cfg.settings;
            };
          }
          (extraConfig cfg)
        ]);
    };

  mkModeMappingsOption =
    mode: defaults:
    mkOption {
      type = with types; attrsOf strLuaFn;
      default = { };
      description = ''
        Keymaps in ${mode} mode.

        Default:
        ```nix
          ${defaults}
        ```
      '';
      apply = mapAttrs (_: mkRaw);
    };

  mkMappingsOption =
    { insertDefaults, normalDefaults }:
    {
      i = mkModeMappingsOption "insert" insertDefaults;
      n = mkModeMappingsOption "normal" normalDefaults;
    };
}

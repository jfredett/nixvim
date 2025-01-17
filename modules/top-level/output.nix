{
  pkgs,
  config,
  lib,
  helpers,
  ...
}:
let
  inherit (lib) types mkOption;
  inherit (lib) optional optionalString optionalAttrs;
in
{
  options = {
    viAlias = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Symlink `vi` to `nvim` binary.
      '';
    };

    vimAlias = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Symlink `vim` to `nvim` binary.
      '';
    };

    withRuby = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Ruby provider.";
    };

    withNodeJs = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Node provider.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.neovim-unwrapped;
      description = "Neovim to use for NixVim.";
    };

    wrapRc = mkOption {
      type = types.bool;
      description = "Should the config be included in the wrapper script.";
      default = false;
    };

    finalPackage = mkOption {
      type = types.package;
      description = "Wrapped Neovim.";
      readOnly = true;
    };

    initPath = mkOption {
      type = types.str;
      description = "The path to the `init.lua` file.";
      readOnly = true;
      visible = false;
    };

    printInitPackage = mkOption {
      type = types.package;
      description = "A tool to show the content of the generated `init.lua` file.";
      readOnly = true;
      visible = false;
    };
  };

  config =
    let
      # Plugin normalization
      normalize =
        p:
        let
          defaultPlugin = {
            plugin = null;
            config = null;
            optional = false;
          };
        in
        defaultPlugin // (if p ? plugin then p else { plugin = p; });
      normalizePluginList = plugins: map normalize plugins;

      # Byte compiling of normalized plugin list
      byteCompilePlugins =
        plugins:
        let
          byteCompile =
            p:
            (helpers.byteCompileLuaDrv p).overrideAttrs (
              prev: lib.optionalAttrs (prev ? dependencies) { dependencies = map byteCompile prev.dependencies; }
            );
        in
        map (p: p // { plugin = byteCompile p.plugin; }) plugins;

      # Normalized and optionally byte compiled plugin list
      normalizedPlugins =
        let
          normalized = normalizePluginList config.extraPlugins;
        in
        if config.performance.byteCompileLua.enable && config.performance.byteCompileLua.plugins then
          byteCompilePlugins normalized
        else
          normalized;

      # Plugin list extended with dependencies
      allPlugins =
        let
          pluginWithItsDeps =
            p: [ p ] ++ builtins.concatMap pluginWithItsDeps (normalizePluginList p.plugin.dependencies or [ ]);
        in
        lib.unique (builtins.concatMap pluginWithItsDeps normalizedPlugins);

      # Remove dependencies from all plugins in a list
      removeDependencies = ps: map (p: p // { plugin = removeAttrs p.plugin [ "dependencies" ]; }) ps;

      # Separated start and opt plugins
      partitionedOptStartPlugins = builtins.partition (p: p.optional) allPlugins;
      startPlugins = partitionedOptStartPlugins.wrong;
      # Remove opt plugin dependencies since they are already available in start plugins
      optPlugins = removeDependencies partitionedOptStartPlugins.right;

      # Test if plugin shouldn't be included in plugin pack
      isStandalone =
        p:
        builtins.elem p.plugin config.performance.combinePlugins.standalonePlugins
        || builtins.elem (lib.getName p.plugin) config.performance.combinePlugins.standalonePlugins;

      # Separated standalone and combined start plugins
      partitionedStandaloneStartPlugins = builtins.partition isStandalone startPlugins;
      toCombinePlugins = partitionedStandaloneStartPlugins.wrong;
      # Remove standalone plugin dependencies since they are already available in start plugins
      standaloneStartPlugins = removeDependencies partitionedStandaloneStartPlugins.right;

      # Combine start plugins into a single pack
      pluginPack =
        let
          # Every plugin has its own generated help tags (doc/tags)
          # Remove them to avoid collisions, new help tags
          # will be generate for the entire pack later on
          overriddenPlugins = map (
            plugin:
            plugin.plugin.overrideAttrs (prev: {
              nativeBuildInputs = lib.remove pkgs.vimUtils.vimGenDocHook prev.nativeBuildInputs or [ ];
              configurePhase = ''
                ${prev.configurePhase or ""}
                rm -vf doc/tags'';
            })
          ) toCombinePlugins;

          # Python3 dependencies
          python3Dependencies =
            let
              deps = map (p: p.plugin.python3Dependencies or (_: [ ])) toCombinePlugins;
            in
            ps: builtins.concatMap (f: f ps) deps;

          # Combined plugin
          combinedPlugin = pkgs.vimUtils.toVimPlugin (
            pkgs.buildEnv {
              name = "plugin-pack";
              paths = overriddenPlugins;
              inherit (config.performance.combinePlugins) pathsToLink;
              # Remove empty directories and activate vimGenDocHook
              postBuild = ''
                find $out -type d -empty -delete
                runHook preFixup
              '';
              passthru = {
                inherit python3Dependencies;
              };
            }
          );

          # Combined plugin configs
          combinedConfig = builtins.concatStringsSep "\n" (
            builtins.concatMap (x: lib.optional (x.config != null && x.config != "") x.config) toCombinePlugins
          );
        in
        normalize {
          plugin = combinedPlugin;
          config = combinedConfig;
        };

      # Combined plugins
      combinedPlugins = [ pluginPack ] ++ standaloneStartPlugins ++ optPlugins;

      # Plugins to use in finalPackage
      plugins = if config.performance.combinePlugins.enable then combinedPlugins else normalizedPlugins;

      neovimConfig = pkgs.neovimUtils.makeNeovimConfig (
        {
          inherit (config)
            extraPython3Packages
            extraLuaPackages
            viAlias
            vimAlias
            withRuby
            withNodeJs
            ;
          # inherit customRC;
          inherit plugins;
        }
        # Necessary to make sure the runtime path is set properly in NixOS 22.05,
        # or more generally before the commit:
        # cda1f8ae468 - neovim: pass packpath via the wrapper
        // optionalAttrs (lib.functionArgs pkgs.neovimUtils.makeNeovimConfig ? configure) {
          configure.packages = {
            nixvim = {
              start = map (x: x.plugin) plugins;
              opt = [ ];
            };
          };
        }
      );

      customRC = helpers.concatNonEmptyLines [
        (helpers.wrapVimscriptForLua neovimConfig.neovimRcContent)
        config.content
      ];

      textInit = helpers.writeLua "init.lua" customRC;
      byteCompiledInit = helpers.writeByteCompiledLua "init.lua" customRC;
      init =
        if
          config.type == "lua"
          && config.performance.byteCompileLua.enable
          && config.performance.byteCompileLua.initLua
        then
          byteCompiledInit
        else
          textInit;

      extraWrapperArgs = builtins.concatStringsSep " " (
        (optional (
          config.extraPackages != [ ]
        ) ''--prefix PATH : "${lib.makeBinPath config.extraPackages}"'')
        ++ (optional config.wrapRc ''--add-flags -u --add-flags "${init}"'')
      );

      package =
        if config.performance.byteCompileLua.enable && config.performance.byteCompileLua.nvimRuntime then
          # Using symlinkJoin to avoid rebuilding neovim
          pkgs.symlinkJoin {
            name = "neovim-byte-compiled-${lib.getVersion config.package}";
            paths = [ config.package ];
            # Required attributes from original neovim package
            inherit (config.package) lua meta;
            nativeBuildInputs = [ helpers.byteCompileLuaHook ];
            postBuild = ''
              # Replace Nvim's binary symlink with a regular file,
              # or Nvim will use original runtime directory
              rm $out/bin/nvim
              cp ${config.package}/bin/nvim $out/bin/nvim

              runHook postFixup
            '';
          }
        else
          config.package;

      wrappedNeovim = pkgs.wrapNeovimUnstable package (
        neovimConfig
        // {
          wrapperArgs = lib.escapeShellArgs neovimConfig.wrapperArgs + " " + extraWrapperArgs;
          wrapRc = false;
        }
      );
    in
    {
      finalPackage = wrappedNeovim;
      initPath = "${init}";

      printInitPackage = pkgs.writeShellApplication {
        name = "nixvim-print-init";
        runtimeInputs = [ pkgs.bat ];
        text = ''
          bat --language=lua "${textInit}"
        '';
      };

      extraConfigLuaPre = lib.mkIf config.wrapRc ''
        -- Ignore the user lua configuration
        vim.opt.runtimepath:remove(vim.fn.stdpath('config'))              -- ~/.config/nvim
        vim.opt.runtimepath:remove(vim.fn.stdpath('config') .. "/after")  -- ~/.config/nvim/after
        vim.opt.runtimepath:remove(vim.fn.stdpath('data') .. "/site")     -- ~/.local/share/nvim/site
      '';

      extraPlugins = lib.mkIf config.wrapRc [ config.filesPlugin ];
    };
}

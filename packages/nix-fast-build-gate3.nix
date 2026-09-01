{unstablePkgs}:
unstablePkgs.python3Packages.buildPythonApplication (finalAttrs: {
  pname = "nix-fast-build";
  version = "2.0.1";
  pyproject = true;
  __structuredAttrs = true;

  src = unstablePkgs.fetchFromGitHub {
    owner = "Mic92";
    repo = "nix-fast-build";
    tag = finalAttrs.version;
    hash = "sha256-VOzpaf8Si/c7B5xXwxZi+i34LKoDaMgPNZbSMZkpXP4=";
  };

  build-system = [unstablePkgs.python3Packages.setuptools];

  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (unstablePkgs.lib.makeBinPath [
      unstablePkgs.nix-eval-jobs
      unstablePkgs.nix-eval-jobs.nix
      unstablePkgs.bashInteractive
    ])
  ];

  nativeCheckInputs = with unstablePkgs.python3Packages; [
    pyte
    pytestCheckHook
  ];

  enabledTestPaths = [
    "tests/test_ci_renderer.py"
    "tests/test_log_format.py"
    "tests/test_term.py"
    "tests/test_tty_renderer.py"
  ];

  pythonImportsCheck = ["nix_fast_build"];

  postPatch = ''
    substituteInPlace nix_fast_build/options.py \
      --replace-fail \
        '        fail_fast=a.fail_fast,' \
        $'        retries=a.retries,\n        fail_fast=a.fail_fast,'
  '';

  passthru = {
    updateScript = unstablePkgs.nix-update-script {};
  };

  meta = {
    description = "Speed-up your Nix evaluation and building process by running them in parallel";
    homepage = "https://github.com/Mic92/nix-fast-build";
    changelog = "https://github.com/Mic92/nix-fast-build/releases/tag/${finalAttrs.version}";
    license = unstablePkgs.lib.licenses.mit;
    maintainers = with unstablePkgs.lib.maintainers; [
      getchoo
      mic92
    ];
    mainProgram = "nix-fast-build";
  };
})

{
  inputs.subject.url = "path:@SUBJECT@";
  outputs = {
    self,
    subject,
  }: let
    pkgs = import subject.inputs."nixpkgs-darwin" {system = "aarch64-darwin";};
  in {
    ci.failure.intentional = pkgs.runCommand "ci-intentional-failure" {} ''
      echo 'intentional hosted acceptance failure' >&2
      exit 42
    '';
  };
}

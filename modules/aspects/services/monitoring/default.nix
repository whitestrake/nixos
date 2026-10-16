{den, ...}: {
  den.aspects.monitoring = {
    includes = [
      den.aspects.beszel
      den.aspects.alloy
    ];
  };
}

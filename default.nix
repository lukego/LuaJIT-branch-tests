{ pkgs ? import <nixpkgs> {},
  luajitName ? "unknown",
  luajitSrc,
  testsuiteSrc ? null,
  benchmarkRuns ? 1 }:

with pkgs;
with stdenv;

rec {
  # Build LuaJIT for testing
  luajit = mkDerivation {
    name = "luajit-${luajitName}";
    src = luajitSrc;
    enableParallelBuilding = true;
    installPhase = ''
      make install PREFIX=$out
      ln -s $out/bin/luajit-* $out/bin/luajit
    '';
  };

  # Build LuaJIT with -Werror to check for compile issues
  luajit-compile-Werror = lib.overrideDerivation luajit (old: {
    name = "luajit-Werror";
    phases = "unpackPhase buildPhase";
    NIX_CFLAGS_COMPILE = "-Werror";
  });

  # Run the standard LuaJIT benchmarks many times and produce a CSV file.
  benchmarks = mkDerivation {
    name = "luajit-benchmarks";
    src = testsuiteSrc;
    buildInputs = [ luajit linuxPackages.perf ];
    buildPhase = ''
      PATH=luajit/bin:$perf/bin:$PATH
      # Run multiple sets of benchmarks
      for run in $(seq 1 ${toString benchmarkRuns}); do
        echo "Run $run"
        mkdir -p result/$run
        # Run each individual benchmark
        for benchscript in bench/*.lua; do
          benchmark=$(basename -s.lua -a $benchscript)
          echo "running $benchmark"
          # Execute with performance monitoring & time supervision
          (cd bench;
           timeout -sKILL 60 \
             perf stat -x, -o ../result/$run/$benchmark.perf \
             luajit $benchmark.lua 1>/dev/null) || true
        done
      done
    '';
    installPhase = ''
      # Copy the raw perf output for reference
      cp -r result $out
      # Create a CSV file
      echo "luajit,benchmark,run,instructions,cycles" > $out/bench.csv
      for resultdir in result/*; do
        run=$(basename $resultdir)
        # Create the rows based on the perf logs
        for result in $resultdir/*.perf; do
          luajit=${luajit.name}
          benchmark=$(basename -s.perf -a $result)
          instructions=$(awk -F, -e '$3 == "instructions" { print $4; }' $result)
          cycles=$(      awk -F, -e '$3 == "cycles"       { print $4; }' $result)
          echo $luajit,$benchmark,$run,$instructions,$cycles >> $out/bench.csv
        done
      done
    '';
  };

  benchmarkResults = mkDerivation {
    name = "benchmark-results";
    buildInputs = with pkgs.rPackages; [ rmarkdown ggplot2 dplyr pkgs.R pkgs.pandoc pkgs.which ];
    builder = pkgs.writeText "builder.csv" ''
      source $stdenv/setup
      # Get the CSV file
      mkdir -p $out/nix-support
      cp ${benchmarks}/bench.csv $out/
      echo "file CSV $out/bench.csv" >> $out/nix-support/hydra-build-products
      # Generate the report
      cp ${./benchmark-results.Rmd} benchmark-results.Rmd
      cp ${benchmarks}/bench.csv .
      cat benchmark-results.Rmd
      echo "library(rmarkdown); render('benchmark-results.Rmd')"| R --no-save
      cp benchmark-results.html $out
      echo "file HTML $out/benchmark-results.html"  >> $out/nix-support/hydra-build-products
    '';
  };

}


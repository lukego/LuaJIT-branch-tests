{ pkgs ? import <nixpkgs> {},
  luajitAname ? "unknown",
  luajitBname,
  luajitCname,
  luajitDname,
  luajitEname,
  luajitAsrc,
  luajitBsrc,
  luajitCsrc,
  luajitDsrc,
  luajitEsrc,
  testsuiteSrc,
  hardware ? null,
  benchmarkRuns ? 1 }:

with pkgs;
with stdenv;

# LuaJIT build derivation
let buildLuaJIT = luajitName: luajitSrc: mkDerivation {
    name = "luajit-${luajitName}";
    version = luajitName;
    src = luajitSrc;
    enableParallelBuilding = true;
    installPhase = ''
      make install PREFIX=$out
      if [ ! -e $out/bin/luajit ]; then
        ln -s $out/bin/luajit-* $out/bin/luajit
      fi
    '';
  }; in

# LuaJIT benchmark run derivatin
# Run the standard LuaJIT benchmarks many times and produce a CSV file.
let benchmarkLuaJIT = luajitName: luajitSrc:
  let luajit = (buildLuaJIT luajitName luajitSrc); in
  mkDerivation {
    name = "luajit-${luajitName}-benchmarks";
    src = testsuiteSrc;
    # Force consistent hardware
    requiredSystemFeatures = if hardware != null then [hardware] else [];
    buildInputs = [ luajit linuxPackages.perf ];
    buildPhase = ''
      PATH=luajit/bin:$perf/bin:$PATH
      # Run multiple iterations of the benchmarks
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
             luajit -e "math.randomseed($run) arg={} dofile('$benchmark.lua')" 1>/dev/null) || true
        done
      done
    '';
    installPhase = ''
      # Copy the raw perf output for reference
      cp -r result $out
      # Create a CSV file
      for resultdir in result/*; do
        run=$(basename $resultdir)
        # Create the rows based on the perf logs
        for result in $resultdir/*.perf; do
          luajit=${luajit.version}
          benchmark=$(basename -s.perf -a $result)
          instructions=$(awk -F, -e '$3 == "instructions" { print $1; }' $result)
          cycles=$(      awk -F, -e '$3 == "cycles"       { print $1; }' $result)
          echo $luajit,$benchmark,$run,$instructions,$cycles >> $out/bench.csv
        done
      done
    '';
  }; in

rec {
  # Build LuaJIT with -Werror to check for compile issues
  luajit-compile-Werror = lib.overrideDerivation luajit (old: {
    name = "luajit-Werror";
    phases = "unpackPhase buildPhase";
    NIX_CFLAGS_COMPILE = "-Werror";
  });

  benchmarksA = (benchmarkLuaJIT luajitAname luajitAsrc);
  benchmarksB = (benchmarkLuaJIT luajitBname luajitBsrc);
  benchmarksC = (benchmarkLuaJIT luajitCname luajitCsrc);
  benchmarksD = (benchmarkLuaJIT luajitDname luajitDsrc);
  benchmarksE = (benchmarkLuaJIT luajitEname luajitEsrc);

  benchmarkResults = mkDerivation {
    name = "benchmark-results";
    buildInputs = with pkgs.rPackages; [ rmarkdown ggplot2 dplyr pkgs.R pkgs.pandoc pkgs.which ];
    builder = pkgs.writeText "builder.csv" ''
      source $stdenv/setup
      # Get the CSV file
      mkdir -p $out/nix-support
      echo "luajit,benchmark,run,instructions,cycles" > bench.csv
      cat ${benchmarksA}/bench.csv ${benchmarksB}/bench.csv ${benchmarksC}/bench.csv \
          ${benchmarksD}/bench.csv ${benchmarksE}/bench.csv \
          >> bench.csv
      cp bench.csv $out
      echo "file CSV $out/bench.csv" >> $out/nix-support/hydra-build-products
      # Generate the report
      cp ${./benchmark-results.Rmd} benchmark-results.Rmd
      cat benchmark-results.Rmd
      echo "library(rmarkdown); render('benchmark-results.Rmd')"| R --no-save
      cp benchmark-results.html $out
      echo "file HTML $out/benchmark-results.html"  >> $out/nix-support/hydra-build-products
    '';
  };
}


# miint patches to HMMER

Branch `v3.4-miint` is HMMER tag `hmmer-3.4` (`9acd8b6`) plus the commits listed below.
[duckdb-miint](https://github.com/the-miint/duckdb-miint) links this HMMER and its Easel into DuckDB, natively and
as WebAssembly (duckdb-wasm). The same branch also builds the command-line programs that duckdb-miint's parity tests
use as their oracle.

That use sets four requirements stock HMMER 3.4 does not meet:

- **In-process.** HMMER runs inside the host's process. Reachable errors must return a status to the caller, never
  `exit()` or `abort()` the host.
- **Untrusted input.** Profile files come from users. A malformed one must fail with `eslEFORMAT` and a message,
  never crash or return a half-built model.
- **WebAssembly.** The libraries must compile with Emscripten, SSE code included (emulated on wasm SIMD128).
- **Parity.** In-process scores must match the CLI oracle. Neither duckdb-miint nor the oracle may turn on the x86
  flush-to-zero (FTZ) or denormals-are-zero (DAZ) modes, which change floating point results.

Each commit is either an upstream commit cherry-picked with `-x` (its message ends "cherry picked from commit …")
or a miint patch. Every miint code change carries a test that failed before it and passes after, or an audit
where no failing test is possible (noted).

## Easel submodule

Easel is the submodule at `./easel`. It tracks [the-miint/easel](https://github.com/the-miint/easel), branch
`v0.49-miint` (Easel `easel-0.49` plus miint patches; see `easel/miint/README.md`). Stock HMMER expects a separate
Easel clone at `./easel` and lists it in `.gitignore`; this fork tracks it as a submodule instead. Clone with:

```sh
git clone --recurse-submodules -b v3.4-miint https://github.com/the-miint/hmmer.git
```

In an existing clone, run `git submodule update --init`.

## Patch series (oldest first)

| Commit | Source | Change and why | Test |
|---|---|---|---|
| `46228708` | miint | Adds the Easel submodule and drops `easel` from `.gitignore`. | — |
| `6d40a08f` | miint | Points the submodule at the miint Easel patches. | HMMER's and Easel's `make check`. |
| `edf8f18e` | upstream `c2827afa` | `read_asc{20,30}hmm()` set `eslEFORMAT` where they returned an unset status. | `utest_bad_header` (`bf752edc`). |
| `c4e55d33` | upstream `d06a8037` | More error handling in the same parsers. It also removes the catch-all that mapped any leftover status to `eslEFORMAT`. | `utest_bad_header`. |
| `64f872ba` | upstream `7eda1785` | The 3.x text parser requires an alphabet before it allocates the model. With no `ALPH` line, stock 3.4 called `p7_hmm_CreateBody()` with a NULL alphabet and segfaulted. | `utest_bad_header`: segfault before, `eslEFORMAT` after. |
| `bf752edc` | miint (test only) | `utest_bad_header` reads damaged headers through `p7_hmmfile_OpenBuffer()`, the path duckdb-miint uses: no `ALPH` line, an unknown `ALPH`, `LENG 0`, `LENG` with no value. Each must give `eslEFORMAT`, a message in `hfp->errbuf`, and no model. | Itself. Only the no-`ALPH` case fails on stock 3.4. The other cases guard against a status left unset now that `d06a8037` removed the catch-all. |
| `ef727447` | upstream `bb7c3e10` (#339) | `biased_byteify()` cast a negative float to `uint8_t`, which is undefined behaviour. x86 wraps the value, but WebAssembly saturates it to 0, so on wasm no target passed the MSV filter. | `miint/check.sh` `ubsan-float-cast` (`b6bf68d6`): before, "p7_oprofile.c:672: -4 is outside the range of representable values of type 'unsigned char'". On x86, output is unchanged. |
| `b6bf68d6` | miint (check only) | Adds `miint/check.sh` and its first check, `ubsan-float-cast`. | Itself. |
| `ffc4d187` | upstream `d92891e0` (#341) | `p7_hmm_SetConsensus()` read out of bounds for a single-sequence model with degenerate residues. | `utest_single_consensus` (`f98a0a5c`): before, the consensus came back lower case and valgrind reported an invalid read. |
| `f98a0a5c` | miint (test only) | `utest_single_consensus`. | Itself. |
| `538f3db7` | upstream `a37e75bb` (#348) | Off-by-one in `is_multidomain_region()`: a domain starting at residue z was counted as starting after z. | `utest_multidomain_region` (`94805558`): before, "one domain, 5..5, seen as multidomain". |
| `94805558` | miint (test only) | `p7_domaindef.c` gets a test driver, registered in `src/Makefile.in` and `testsuite/testsuite.sqc` (a level-1 exercise and a level-3 valgrind run), with `utest_multidomain_region`. | Itself. |
| `47de2062` | upstream `37f71489` (#350) | The parsers reject a model length M above `p7_MAXM` (100000, now in `p7_config.h.in`). Upstream's concern: an adversarial file could otherwise cause a buffer overflow. | Upstream's `utest_bad_M`. |
| `07772e14` | upstream `64949bfc` (#320) | Zeroes `fwd_emissions_arr` in nhmmer's pipeline, an uninitialized read reported by MSan. | None possible here. There is no clang/MSan on the build host, and before the fix valgrind finds nothing on the tutorial nhmmer run. nhmmer's output is identical before and after. |
| `d396f20e` | miint | Process exits become error returns on in-process paths. `reparameterize_model()`'s `p7_Fail()` becomes `ESL_EXCEPTION()`, and its two callers that pass a sequence check the status. Six scan-branch `esl_fatal("allocation failure")` calls in `p7_Pipeline()` and `p7_pli_postViterbi_LongTarget()` become `ESL_EXCEPTION(eslEMEM, …)`. Both `p7_tophits_CreateNextHit()` calls check their status. | `miint/check.sh` `fatal-audit`: 11 sites before, 0 after. These are out-of-memory and can't-happen paths, so an audit stands in for a test. |
| `3581125d` | miint | Adds `p7_hit_IsDuplicateDomain(const P7_HIT *hit, int d)` (declared in `hmmer.h`). It gives bug #h74's verdict for one hit, the domain that `p7_tophits_Threshold()`'s static `workaround_bug_h74()` would hide, without side effects. duckdb-miint streams domains and never calls `Threshold()`. | `utest_duplicate_domains`: fixed cases, `noverlaps == 0`, NaN scores, then 500 random hits compared against what `workaround_bug_h74()` actually hides. |
| `ad7e3429` | miint | `read_asc20hmm()` (HMMER2.0 profiles) rejects a missing or unknown `ALPH` with `eslEFORMAT`. Before, it segfaulted on a NULL alphabet. After `d06a8037` it also returned `eslOK` with no model for an unknown `ALPH`, because `ESL_XFAIL(status, …)` ran while `status` was still `eslOK`. Upstream develop has the same line. | `utest_bad_h2_header`: before, a segfault in `read_asc20hmm()`; with only the `eslOK` line reverted, "status 0, not eslEFORMAT". |
| `11ab5805` | miint | `impl_sse/decoding.c` includes `<emmintrin.h>`, not `<x86intrin.h>`, which exists only on x86. | `miint/check.sh` `emcc-build`: before, the build failed at `decoding.o`. |
| `66d3a8fb` | miint | FTZ/DAZ are never set. `configure.ac` loses its FTZ probe, so `HAVE_FLUSH_ZERO_MODE` is never defined. `impl_Init()` set DAZ in any SSE3 build (`-msse3`, or any `-march` that implies it), whatever configure decided; it now also requires `HAVE_DENORMALS_ZERO_MODE`, which nothing defines. | `miint/check.sh` `ftz-daz-off`: "FTZ on, DAZ on" before; "FTZ off, DAZ on" after the configure change alone; pass after both. |
| `0f4f0974` | miint (test only) | `p7_hmmd_search_stats_utest` aborted in about 0.6% of runs: its clock-seeded generator sometimes asked `ESL_ALLOC` for a zero-length `hit_offsets` array, which Easel treats as an exception. It now makes an array only when `nhits > 0`, the only case the serialized form can represent. The code under test (hmmpgmd's) is unchanged. Stock 3.4 and upstream develop have the same test. | With the clock seed replaced by fixed seeds 1–3000: 17 aborts before, 0 after. |
| `109f4e48` | miint | Points the submodule at Easel with upstream `3fd1f3f`: `esl_sq_Copy()` copies a NULL markup tag or annotation as NULL. | Easel's `utest_CopyNullMarkup`. |

Housekeeping commits sit among them: `.gitignore` entries, a refactor of the parser tests' shared must-fail check
into `expect_eformat()`, this README, and a submodule bump for the Easel README.

On the tutorial examples, the fork's output is identical to stock 3.4's: `hmmsearch` on `globins4`, `fn3` and
`Pkinase`, and `nhmmer` on `MADE1`.

## Testing

```sh
autoconf && ./configure && make && make check    # Easel's 87 exercises, then HMMER's 308 (default level)
miint/check.sh                                   # the environment checks below; or name checks to run a subset
```

`make check` runs the unit tests above, because they live in HMMER's own test drivers. `miint/check.sh` (run from
any directory) covers the cases a test driver cannot set up for itself. It builds in `build-miint-*/`, which
`build-*` keeps out of git:

| Check | What it proves | Needs |
|---|---|---|
| `fatal-audit` | The functions listed below contain no process exit (`p7_Fail`, `p7_Die`, `esl_fatal`, `exit`, `abort`) and no bare call that drops a status that must be checked. | — |
| `ubsan-float-cast` | `hmmsearch` on the tutorial globins makes no out-of-range float-to-integer cast. | gcc or clang with `-fsanitize=float-cast-overflow` |
| `emcc-build` | Easel, libdivsufsort and `libhmmer.a` (with `impl_sse`) compile for WebAssembly with `--enable-sse` and `-msimd128 -msse -msse2`, and configure enabled the SSE code. | `emconfigure`/`emcc` on `PATH` (tested with emsdk 6.0.9 and 3.1.71) |
| `ftz-daz-off` | `impl_Init()` leaves FTZ and DAZ off. `miint/ftzdaz_check.c`, built with `-msse3` (the case where stock 3.4 set DAZ), calls it and reads MXCSR back. | an x86 host |

A missing tool prints `SKIP` with the reason, and the summary lists it again. The script exits 1 if any check
fails. Easel's environment checks are in `easel/miint/check.sh`. The two scripts' helpers (`pass`, `fail`, `skip`,
`step`) are duplicated on purpose: each fork stands alone.

### The fatal-audit function list

`fatal-audit` checks only the functions listed in `AUDIT_FUNCS` in `miint/check.sh`:

- `src/p7_domaindef.c`: `reparameterize_model`, `rescore_isolated_domain`
- `src/p7_pipeline.c`: `p7_Pipeline`, `p7_pli_postViterbi_LongTarget`

These are the paths patched so far. As duckdb-miint reaches more of HMMER, each function it adds to its
in-process path joins this list, along with any must-check calls in `AUDIT_MUST_CHECK`.

### Why no `p7_Fail` handler

`p7_Fail()` and `p7_Die()` print and call `exit(1)`. Unlike Easel's exceptions, they have no handler a host can
replace. This fork does not add one. Neither function is declared no-return, and their callers carry on after
them as if they cannot return, so a handler that returned would let the callers run on with bad state. Instead,
each site duckdb-miint can reach becomes an error return (`d396f20e`). The other `p7_Fail()`/`esl_fatal()` sites
stay, because they are in programs' `main()`s, test drivers, or paths duckdb-miint does not run. `fatal-audit` keeps the reachable set clean.

Easel's `ESL_EXCEPTION()` still aborts when no handler is installed, as the command-line programs expect. An
in-process host must install one with `esl_exception_SetHandler()` before calling into HMMER.

## Known upstream bugs left alone

duckdb-miint reaches neither, so neither gets a patch here. Easel's is listed in `easel/miint/README.md`.

- `p7_hmmfile.c:315`, in `open_engine()`'s search for a pressed `.h3m` beside the named file:
  `(status = esl_sprintf(...) != eslOK)` assigns the comparison, so on an allocation failure `status` is 1
  (`eslFAIL`), not `eslEMEM`. `p7_hmmfile_OpenBuffer()` never runs it. Upstream develop is the same.
- `impl_neon/impl_neon.h`'s `impl_Init()` has the same DAZ gate as stock `impl_sse.h` (`#ifdef
  _PMMINTRIN_H_INCLUDED`). `<pmmintrin.h>` is an x86 header, so on ARM the gate never fires.

## Building the parity oracle

duckdb-miint's parity tests compare its results with this fork's command-line programs, built with default
configure settings:

```sh
git clone --recurse-submodules -b v3.4-miint https://github.com/the-miint/hmmer.git
cd hmmer
git checkout <commit duckdb-miint pins> && git submodule update
autoconf && ./configure && make -j
```

The programs are `src/hmmsearch`, `src/nhmmer` and `src/hmmbuild`. On x86 the defaults build the SSE
implementation with POSIX threads on.

- **HMMER never turns FTZ/DAZ on, whatever the architecture flags** (`-msse3`, `-march=native`, …).
  `miint/check.sh ftz-daz-off` proves it for `-msse3`, the case stock 3.4 got wrong. Only defining
  `HAVE_FLUSH_ZERO_MODE` or `HAVE_DENORMALS_ZERO_MODE` by hand turns them back on. Don't build the oracle with
  `-ffast-math` or `-Ofast`: with those, gcc (and some clang versions) link `crtfastmath.o`, which turns FTZ/DAZ
  on before `main()`.
- **A target's scores and domains do not depend on threads or target order.** `--seed` defaults to 42. With a
  nonzero seed, the pipeline resets its RNG to that seed before each stochastic trace ensemble
  (`region_trace_ensemble()`, `src/p7_domaindef.c`). So a target's domains depend neither on `--cpu` nor on the
  targets searched before it. `--seed 0` turns the reset off, and results are then not reproducible.

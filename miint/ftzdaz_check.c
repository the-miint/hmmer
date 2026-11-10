/* ftzdaz_check: driver for the ftz-daz-off check in miint/check.sh.
 *
 * Calls impl_Init(), the SIMD setup every HMMER program runs first,
 * and reports whether it turned on flush-to-zero (FTZ) or
 * denormals-are-zero (DAZ) in this thread's MXCSR. Exits 0 if neither,
 * 1 if either, 2 if they were already on (the check proves nothing).
 *
 * Built with -msse3 so that impl_sse.h includes <pmmintrin.h>: stock
 * HMMER 3.4 then sets DAZ whatever configure decided, because
 * impl_Init() tested _PMMINTRIN_H_INCLUDED rather than a configure
 * symbol. FTZ came from configure's HAVE_FLUSH_ZERO_MODE.
 *
 * Why: FTZ/DAZ change floating point results. miint never sets them
 * (it never calls impl_Init()), so the CLI it uses as its parity
 * oracle must not either, whatever flags the CLI is built with.
 */
#include <p7_config.h>

#ifndef __SSE3__
#error "build with -msse3: this check needs impl_sse.h's <pmmintrin.h> path"
#endif

#include <stdio.h>

#include "easel.h"
#include "hmmer.h"
#include "impl_sse.h"

int
main(void)
{
  int ftz, daz;

  if (_MM_GET_FLUSH_ZERO_MODE()     != _MM_FLUSH_ZERO_OFF ||
      _MM_GET_DENORMALS_ZERO_MODE() != _MM_DENORMALS_ZERO_OFF)
    {
      printf("FTZ/DAZ already on before impl_Init()\n");
      return 2;
    }

  impl_Init();
  ftz = (_MM_GET_FLUSH_ZERO_MODE()     == _MM_FLUSH_ZERO_ON);
  daz = (_MM_GET_DENORMALS_ZERO_MODE() == _MM_DENORMALS_ZERO_ON);
  printf("after impl_Init(): FTZ %s, DAZ %s\n", ftz ? "on" : "off", daz ? "on" : "off");
  return (ftz || daz) ? 1 : 0;
}

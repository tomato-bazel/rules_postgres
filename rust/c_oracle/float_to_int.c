/*
 * float_to_int.c — vendored float-to-int cast V1 fmgr bodies from Postgres 17.6.
 * Function bodies are BYTE-IDENTICAL to real Postgres source modulo
 * the standalone preamble.
 *
 * Attribution: function bodies are PostgreSQL Global Development Group,
 * released under the PostgreSQL License (BSD-style).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

typedef float float4;
typedef double float8;
typedef int16_t int16;
typedef int32_t int32;
typedef uintptr_t Datum;
typedef void *fmNodePtr;
#define FLEXIBLE_ARRAY_MEMBER

typedef struct NullableDatum {
    Datum value;
    bool  isnull;
} NullableDatum;

struct FmgrInfo;

typedef struct FunctionCallInfoBaseData {
    struct FmgrInfo *flinfo;
    fmNodePtr        context;
    fmNodePtr        resultinfo;
    uint32_t         fncollation;
    bool             isnull;
    short            nargs;
    NullableDatum    args[FLEXIBLE_ARRAY_MEMBER];
} FunctionCallInfoBaseData;

typedef FunctionCallInfoBaseData *FunctionCallInfo;

#define PG_FUNCTION_ARGS         FunctionCallInfo fcinfo
#define PG_GETARG_FLOAT4(n)      (*(float4 *)&fcinfo->args[n].value)
#define PG_GETARG_FLOAT8(n)      (*(float8 *)&fcinfo->args[n].value)
#define PG_RETURN_INT16(x)       return (Datum) (uint16_t) (x)
#define PG_RETURN_INT32(x)       return (Datum) (uint32_t) (x)

#define ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE \
    MAKE_SQLSTATE('2','2','0','0','3')

#include "c_oracle_ereport.h"

/* Macros for range checking (matching postgres.h definitions).
 * Upper bound is the exclusive power-of-two `-MIN`, not `<= MAX`: as float4,
 * 2147483647.0f rounds up to 2147483648.0f, so `<= 2147483647.0f` would wrongly
 * admit 2^31 (out of int32 range) and then cast it via UB. This mirrors real
 * Postgres' FLOAT*_FITS_IN_INT* (`>= MIN && < -MIN`). */
#define FLOAT4_FITS_IN_INT16(f)  ((f) >= -32768.0f && (f) < 32768.0f)
#define FLOAT4_FITS_IN_INT32(f)  ((f) >= -2147483648.0f && (f) < 2147483648.0f)
#define FLOAT8_FITS_IN_INT16(d)  ((d) >= -32768.0 && (d) < 32768.0)
#define FLOAT8_FITS_IN_INT32(d)  ((d) >= -2147483648.0 && (d) < 2147483648.0)

/* ──────────────────────────────────────────────────────────────── */
/* Bodies below are byte-identical to real Postgres source.         */
/* float.c: ftoi2, ftoi4, dtoi2, dtoi4.                             */
/* ──────────────────────────────────────────────────────────────── */

Datum
ftoi4(PG_FUNCTION_ARGS)
{
	float4		num = PG_GETARG_FLOAT4(0);

	/*
	 * Get rid of any fractional part in the input.  This is so we don't fail
	 * on just-out-of-range values that would round into range.  Note
	 * assumption that rint() will pass through a NaN or Inf unchanged.
	 */
	num = rint(num);

	/* Range check */
	if (unlikely(isnan(num) || !FLOAT4_FITS_IN_INT32(num)))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("integer out of range")));

	PG_RETURN_INT32((int32) num);
}

Datum
ftoi2(PG_FUNCTION_ARGS)
{
	float4		num = PG_GETARG_FLOAT4(0);

	/*
	 * Get rid of any fractional part in the input.  This is so we don't fail
	 * on just-out-of-range values that would round into range.  Note
	 * assumption that rint() will pass through a NaN or Inf unchanged.
	 */
	num = rint(num);

	/* Range check */
	if (unlikely(isnan(num) || !FLOAT4_FITS_IN_INT16(num)))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("smallint out of range")));

	PG_RETURN_INT16((int16) num);
}

Datum
dtoi4(PG_FUNCTION_ARGS)
{
	float8		num = PG_GETARG_FLOAT8(0);

	/*
	 * Get rid of any fractional part in the input.  This is so we don't fail
	 * on just-out-of-range values that would round into range.  Note
	 * assumption that rint() will pass through a NaN or Inf unchanged.
	 */
	num = rint(num);

	/* Range check */
	if (unlikely(isnan(num) || !FLOAT8_FITS_IN_INT32(num)))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("integer out of range")));

	PG_RETURN_INT32((int32) num);
}

Datum
dtoi2(PG_FUNCTION_ARGS)
{
	float8		num = PG_GETARG_FLOAT8(0);

	/*
	 * Get rid of any fractional part in the input.  This is so we don't fail
	 * on just-out-of-range values that would round into range.  Note
	 * assumption that rint() will pass through a NaN or Inf unchanged.
	 */
	num = rint(num);

	/* Range check */
	if (unlikely(isnan(num) || !FLOAT8_FITS_IN_INT16(num)))
		ereport(ERROR,
				(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
				 errmsg("smallint out of range")));

	PG_RETURN_INT16((int16) num);
}

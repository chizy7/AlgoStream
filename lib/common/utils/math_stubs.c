/*
 * Fast mathematical operations C stubs for AlgoStream
 * Optimized implementations for financial calculations
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

#include <math.h>
#include <stdint.h>
#include <string.h>

/*
 * Fast inverse square root (famous Quake algorithm)
 * Used for normalizing vectors and distance calculations
 */
value algostream_fast_inv_sqrt(value x_val) {
    CAMLparam1(x_val);

    float x = (float)Double_val(x_val);
    float xhalf = 0.5f * x;

    /* Convert to integer representation */
    union {
        float f;
        uint32_t i;
    } u;

    u.f = x;
    u.i = 0x5f3759df - (u.i >> 1);  /* Magic number */

    /* Newton-Raphson iteration for better precision */
    u.f = u.f * (1.5f - xhalf * u.f * u.f);
    u.f = u.f * (1.5f - xhalf * u.f * u.f); /* Second iteration for higher precision */

    CAMLreturn(caml_copy_double((double)u.f));
}

/*
 * Fast sine approximation using polynomial approximation
 */
value algostream_fast_sin(value x_val) {
    CAMLparam1(x_val);

    double x = Double_val(x_val);

    /* Normalize x to [-π, π] */
    while (x > M_PI) x -= 2.0 * M_PI;
    while (x < -M_PI) x += 2.0 * M_PI;

    /* Use polynomial approximation for better performance */
    double x2 = x * x;
    double result = x * (1.0 - x2 * (1.0/6.0 - x2 * (1.0/120.0 - x2 / 5040.0)));

    CAMLreturn(caml_copy_double(result));
}

/*
 * Fast cosine approximation
 */
value algostream_fast_cos(value x_val) {
    CAMLparam1(x_val);

    double x = Double_val(x_val);

    /* Normalize x to [-π, π] */
    while (x > M_PI) x -= 2.0 * M_PI;
    while (x < -M_PI) x += 2.0 * M_PI;

    /* Use polynomial approximation */
    double x2 = x * x;
    double result = 1.0 - x2 * (0.5 - x2 * (1.0/24.0 - x2 / 720.0));

    CAMLreturn(caml_copy_double(result));
}

/*
 * Fast exponential approximation using bit manipulation
 */
value algostream_fast_exp2(value x_val) {
    CAMLparam1(x_val);

    double x = Double_val(x_val);

    if (x > 1023.0) {
        CAMLreturn(caml_copy_double(INFINITY));
    }
    if (x < -1023.0) {
        CAMLreturn(caml_copy_double(0.0));
    }

    /* Split into integer and fractional parts */
    int32_t n = (int32_t)x;
    double f = x - n;

    /* Approximate 2^f using polynomial */
    double exp_f = 1.0 + f * (0.693147180559945 + f * (0.240226506959101 + f * 0.055504108664821));

    /* Combine with 2^n using bit manipulation */
    union {
        double d;
        uint64_t i;
    } u;

    u.d = exp_f;
    u.i += ((uint64_t)(n + 1023)) << 52;

    CAMLreturn(caml_copy_double(u.d));
}

/*
 * Fast natural logarithm approximation
 */
value algostream_fast_log2(value x_val) {
    CAMLparam1(x_val);

    double x = Double_val(x_val);

    if (x <= 0.0) {
        CAMLreturn(caml_copy_double(-INFINITY));
    }

    union {
        double d;
        uint64_t i;
    } u;

    u.d = x;

    /* Extract exponent */
    int32_t exp = ((u.i >> 52) & 0x7ff) - 1023;

    /* Normalize mantissa to [1, 2) */
    u.i = (u.i & 0x000fffffffffffffULL) | 0x3ff0000000000000ULL;
    double m = u.d;

    /* Polynomial approximation for log2(m) where m in [1, 2) */
    double log2_m = -1.49278 + m * (2.11263 + m * (-0.729104 + m * 0.10969));

    double result = exp + log2_m;

    CAMLreturn(caml_copy_double(result));
}

/*
 * Fast power function for small integer exponents
 */
value algostream_fast_powi(value base_val, value exp_val) {
    CAMLparam2(base_val, exp_val);

    double base = Double_val(base_val);
    int exp = Int_val(exp_val);

    if (exp == 0) {
        CAMLreturn(caml_copy_double(1.0));
    }

    if (exp < 0) {
        base = 1.0 / base;
        exp = -exp;
    }

    double result = 1.0;
    double current_power = base;

    /* Binary exponentiation */
    while (exp > 0) {
        if (exp & 1) {
            result *= current_power;
        }
        current_power *= current_power;
        exp >>= 1;
    }

    CAMLreturn(caml_copy_double(result));
}

/*
 * Fast square root using bit manipulation and Newton-Raphson
 */
value algostream_fast_sqrt(value x_val) {
    CAMLparam1(x_val);

    double x = Double_val(x_val);

    if (x < 0.0) {
        CAMLreturn(caml_copy_double(NAN));
    }

    if (x == 0.0) {
        CAMLreturn(caml_copy_double(0.0));
    }

    /* Initial guess using bit manipulation */
    union {
        double d;
        uint64_t i;
    } u;

    u.d = x;
    u.i = (u.i >> 1) + (1023LL << 51); /* Initial approximation */

    /* Newton-Raphson iterations */
    double guess = u.d;
    guess = 0.5 * (guess + x / guess);
    guess = 0.5 * (guess + x / guess);

    CAMLreturn(caml_copy_double(guess));
}

/*
 * Fast division using multiplication by reciprocal
 */
value algostream_fast_div(value num_val, value den_val) {
    CAMLparam2(num_val, den_val);

    double num = Double_val(num_val);
    double den = Double_val(den_val);

    if (den == 0.0) {
        if (num > 0.0) {
            CAMLreturn(caml_copy_double(INFINITY));
        } else if (num < 0.0) {
            CAMLreturn(caml_copy_double(-INFINITY));
        } else {
            CAMLreturn(caml_copy_double(NAN));
        }
    }

    /* Use reciprocal multiplication for better performance in tight loops */
    double reciprocal = 1.0 / den;
    double result = num * reciprocal;

    CAMLreturn(caml_copy_double(result));
}

/*
 * Fast modulo operation for floating point
 */
value algostream_fast_fmod(value x_val, value y_val) {
    CAMLparam2(x_val, y_val);

    double x = Double_val(x_val);
    double y = Double_val(y_val);

    if (y == 0.0) {
        CAMLreturn(caml_copy_double(NAN));
    }

    /* Use faster integer division when possible */
    double q = x / y;
    double n = (q >= 0.0) ? floor(q) : ceil(q);
    double result = x - n * y;

    CAMLreturn(caml_copy_double(result));
}

/*
 * Vector dot product optimized with loop unrolling
 */
value algostream_vector_dot(value v1_val, value v2_val) {
    CAMLparam2(v1_val, v2_val);

    mlsize_t len1 = Wosize_val(v1_val);
    mlsize_t len2 = Wosize_val(v2_val);

    if (len1 != len2) {
        caml_failwith("Vector lengths must be equal");
    }

    double sum = 0.0;
    mlsize_t i;

    /* Unroll loop for better performance */
    for (i = 0; i + 3 < len1; i += 4) {
        sum += Double_field(v1_val, i) * Double_field(v2_val, i);
        sum += Double_field(v1_val, i + 1) * Double_field(v2_val, i + 1);
        sum += Double_field(v1_val, i + 2) * Double_field(v2_val, i + 2);
        sum += Double_field(v1_val, i + 3) * Double_field(v2_val, i + 3);
    }

    /* Handle remaining elements */
    for (; i < len1; i++) {
        sum += Double_field(v1_val, i) * Double_field(v2_val, i);
    }

    CAMLreturn(caml_copy_double(sum));
}

/*
 * Matrix multiplication for small matrices (2x2, 3x3, 4x4)
 */
value algostream_matrix_mult_2x2(value a_val, value b_val) {
    CAMLparam2(a_val, b_val);
    CAMLlocal1(result);

    /* Extract matrix elements */
    double a00 = Double_field(Field(a_val, 0), 0);
    double a01 = Double_field(Field(a_val, 0), 1);
    double a10 = Double_field(Field(a_val, 1), 0);
    double a11 = Double_field(Field(a_val, 1), 1);

    double b00 = Double_field(Field(b_val, 0), 0);
    double b01 = Double_field(Field(b_val, 0), 1);
    double b10 = Double_field(Field(b_val, 1), 0);
    double b11 = Double_field(Field(b_val, 1), 1);

    /* Compute result */
    double c00 = a00 * b00 + a01 * b10;
    double c01 = a00 * b01 + a01 * b11;
    double c10 = a10 * b00 + a11 * b10;
    double c11 = a10 * b01 + a11 * b11;

    /* Create result matrix */
    result = caml_alloc(2, 0);
    Store_field(result, 0, caml_alloc(2 * Double_wosize, Double_array_tag));
    Store_field(result, 1, caml_alloc(2 * Double_wosize, Double_array_tag));

    Store_double_field(Field(result, 0), 0, c00);
    Store_double_field(Field(result, 0), 1, c01);
    Store_double_field(Field(result, 1), 0, c10);
    Store_double_field(Field(result, 1), 1, c11);

    CAMLreturn(result);
}
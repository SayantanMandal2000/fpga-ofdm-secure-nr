/*
 * pc_coef.c - ARM/PS side of the 5G-NR phase compensation (paper Sec. III-A)
 *
 * Computes the 14 per-symbol phase-compensation coefficients from the NR
 * up-conversion phase term (3GPP TS 38.211 Sec. 5.4.1):
 *
 *     the standard defines the RF signal of symbol l as
 *         Re{ s_l(t) * exp(j*2*pi*f0*(t - t_start,l - N_CP,l*Tc)) }
 *     a plain mixer produces Re{ s(t) * exp(j*2*pi*f0*t) }, so the baseband
 *     must be pre-multiplied by
 *         c_l = exp(-j*2*pi*f0*(t_start,l + N_CP,l*Tc))
 *
 * Here time is counted in baseband samples of this design:
 *     Ts            = T_slot / samples_per_slot
 *     t_start,l     = sum_{i<l} (N + CP_i) * Ts   (from the slot start)
 *     N_CP,l * Tc   = CP_l * Ts                  (CP_0 = long first-symbol CP)
 *
 * Assumption: f0 * T_slot is an integer (f0 a multiple of 2 kHz for a 0.5 ms
 * slot), so the 14 coefficients repeat every slot. Otherwise the phase moves
 * by 2*pi*f0*T_slot from slot to slot and the PS must rewrite the table (or
 * the FPGA must apply a per-slot phase step).
 *
 * Register format (ofdm_axil_regs): PC_COEF[l] at 0x40 + 4*l,
 *     [31:16] cos(phi_l), [15:0] sin(phi_l), signed Q2.14 (16384 = 1.0)
 *
 * Build for a Zynq/MPSoC standalone BSP with -DUSE_XIL_IO, or on a PC as-is
 * (prints the table).
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#ifdef USE_XIL_IO
#include "xil_io.h"
#include "xparameters.h"
#ifndef OFDM_BASEADDR
#define OFDM_BASEADDR XPAR_OFDM_TOP_0_BASEADDR   /* adjust to your design */
#endif
#endif

#define NSYM 14

typedef struct {
    double f0_hz;      /* carrier frequency                       */
    double t_slot;     /* slot duration [s], 0.5e-3 for 30 kHz SCS */
    int    n_fft;      /* FFT size                                 */
    int    cp;         /* normal CP length [samples]               */
    int    cp0;        /* CP of symbol 0 [samples]                 */
} pc_cfg_t;

static int16_t q14(double v)
{
    double r = v * 16384.0;
    r = (r >= 0.0) ? floor(r + 0.5) : -floor(-r + 0.5);
    if (r >  32767.0) r =  32767.0;
    if (r < -32768.0) r = -32768.0;
    return (int16_t)r;
}

/* fills coef[l] = {cos, sin} words, returns 0 if f0*T_slot is an integer */
int pc_compute(const pc_cfg_t *c, uint32_t coef[NSYM])
{
    const double PI = 3.14159265358979323846;
    int    samples_per_slot = (c->n_fft + c->cp0) + (NSYM - 1) * (c->n_fft + c->cp);
    double ts = c->t_slot / samples_per_slot;
    double st = 0.0;
    double cyc_per_slot = c->f0_hz * c->t_slot;
    int    periodic = fabs(cyc_per_slot - floor(cyc_per_slot + 0.5)) < 1e-6;

    for (int l = 0; l < NSYM; l++) {
        int    cpl = (l == 0) ? c->cp0 : c->cp;
        double cyc = c->f0_hz * ts * (st + cpl);     /* f0*(t_start,l + N_CP,l*Ts) */
        double ph  = -2.0 * PI * (cyc - floor(cyc));
        coef[l] = ((uint32_t)(uint16_t)q14(cos(ph)) << 16) | (uint16_t)q14(sin(ph));
        st += c->n_fft + cpl;
    }
    return periodic ? 0 : -1;
}

#ifdef USE_XIL_IO
void pc_write(uint32_t base, const uint32_t coef[NSYM])
{
    for (int l = 0; l < NSYM; l++)
        Xil_Out32(base + 0x40 + 4 * l, coef[l]);
}
#endif

int main(void)
{
    pc_cfg_t cfg = { 3.5e9, 0.5e-3, 128, 32, 36 };
    uint32_t coef[NSYM];
    int rc = pc_compute(&cfg, coef);
    if (rc) printf("warning: f0*T_slot is not an integer, table changes per slot\n");
    for (int l = 0; l < NSYM; l++)
        printf("PC_COEF[%2d] (0x%02X) = 0x%08X\n", l, 0x40 + 4 * l, (unsigned)coef[l]);
#ifdef USE_XIL_IO
    pc_write(OFDM_BASEADDR, coef);
#endif
    return 0;
}

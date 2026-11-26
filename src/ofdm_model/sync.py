"""Timing-synchroniser model: sign-bit and |P|^2 metrics, energy gate and the RTL frame finder."""
import numpy as np

from . import fx

N = fx.N
TH = {0: 88, 1: 380000}; HOLD = 80; EMIN = 16384

def metrics(yr, yi):
    sr = np.where(yr < 0, -1, 1); si = np.where(yi < 0, -1, 1)
    qr = np.clip(yr >> 7, -8, 7); qi = np.clip(yi >> 7, -8, 7)
    L = len(yr) - N; d = np.arange(L)
    P0r = np.zeros(L); P0i = np.zeros(L); P1r = np.zeros(L); P1i = np.zeros(L)
    for k in range(1, N // 2):
        a, b = d + k, d + N - k
        P0r += sr[a] * sr[b] - si[a] * si[b]; P0i += sr[a] * si[b] + si[a] * sr[b]
        P1r += qr[a] * qr[b] - qi[a] * qi[b]; P1i += qr[a] * qi[b] + qi[a] * qr[b]
    e = np.abs(yr) + np.abs(yi); c = np.concatenate([[0], np.cumsum(e)]); R = c[N:N + L] - c[:L]
    return np.abs(P0r) + np.abs(P0i), P1r ** 2 + P1i ** 2, R

def finder(m, R, th, start):
    best = -1; bi = None; since = 0
    for d in range(start, len(m)):
        if m[d] >= th and R[d] >= EMIN:
            if m[d] > best: best = m[d]; bi = d; since = 0; continue
        if bi is not None:
            since += 1
            if since >= HOLD: return bi
    return bi


def qmetrics(yr, yi):
    qr = np.clip(yr >> 7, -8, 7); qi = np.clip(yi >> 7, -8, 7)
    L = len(yr) - N; d = np.arange(L); Pr = np.zeros(L); Pi = np.zeros(L)
    for k in range(1, N // 2):
        a, b = d + k, d + N - k
        Pr += qr[a] * qr[b] - qi[a] * qi[b]; Pi += qr[a] * qi[b] + qi[a] * qr[b]
    e = np.abs(qr) + np.abs(qi); c = np.concatenate([[0], np.cumsum(e)]); Rq = c[N:N + L] - c[:L]
    return Pr ** 2 + Pi ** 2, Rq


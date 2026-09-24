#!/usr/bin/env python3
"""Generate the matplotlib part of the realworld corpus (T103).

    python3 tests/corpora/realworld/src/gen_matplotlib.py

Writes ../matplotlib/*.svg (default: glyphs as paths) and
../matplotlib-text/*.svg (svg.fonttype='none': real <text>). All randomness
is seeded per plot; svg.hashsalt and metadata Date=None make output stable.
"""
import sys
from pathlib import Path

import matplotlib

matplotlib.use("svg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from scipy import stats  # noqa: E402

HERE = Path(__file__).resolve().parent
OUT = HERE.parent
PLOTS = []


def plot(fn):
    PLOTS.append(fn)
    return fn


# ---------------------------------------------------------------- Bayesian
@plot
def beta_binomial_update(r):
    x = np.linspace(0, 1, 400)
    fig, ax = plt.subplots(figsize=(5, 3.5))
    for a, b, lbl in [(1, 1, "prior Beta(1,1)"), (3, 9, "after 2/10"), (13, 31, "after 12/40"), (41, 81, "after 40/120")]:
        ax.plot(x, stats.beta.pdf(x, a, b), label=lbl)
    ax.set_xlabel(r"$\theta$")
    ax.set_ylabel(r"$p(\theta \mid y)$")
    ax.set_title("Beta-binomial posterior updating")
    ax.legend()
    return fig


@plot
def prior_likelihood_posterior(r):
    x = np.linspace(-4, 6, 500)
    prior = stats.norm.pdf(x, 0, 1.5)
    lik = stats.norm.pdf(x, 2.5, 0.8)
    post = prior * lik
    post /= np.trapezoid(post, x)
    fig, ax = plt.subplots(figsize=(5, 3.2))
    ax.plot(x, prior, "--", label="prior")
    ax.plot(x, lik / np.trapezoid(lik, x), ":", label="likelihood")
    ax.fill_between(x, post, alpha=0.4, label="posterior")
    ax.plot(x, post, color="C2")
    ax.legend(frameon=False)
    ax.set_xlabel(r"$\mu$")
    return fig


@plot
def credible_interval_hdi(r):
    s = r.gamma(3, 1.2, 20000)
    fig, ax = plt.subplots(figsize=(5, 3))
    ax.hist(s, bins=80, density=True, color="0.7")
    lo, hi = np.percentile(s, [3, 97])
    ax.axvspan(lo, hi, color="C0", alpha=0.2)
    ax.axvline(np.mean(s), color="k", lw=1)
    ax.annotate("94% CI", xy=((lo + hi) / 2, 0.02), ha="center")
    ax.set_title(r"Posterior of $\lambda$, mean %.2f" % np.mean(s))
    return fig


@plot
def mcmc_trace(r):
    fig, axes = plt.subplots(3, 2, figsize=(7, 5), gridspec_kw={"width_ratios": [1, 2.5]})
    for i, name in enumerate([r"$\alpha$", r"$\beta$", r"$\sigma$"]):
        for c in range(4):
            chain = np.cumsum(r.normal(0, 0.3, 800)) * 0.02 + r.normal(i, 0.5, 800)
            axes[i, 1].plot(chain, lw=0.5, alpha=0.8)
            axes[i, 0].hist(chain, bins=40, histtype="step", density=True)
        axes[i, 0].set_ylabel(name)
    axes[-1, 1].set_xlabel("iteration")
    fig.tight_layout()
    return fig


@plot
def mcmc_autocorr(r):
    fig, ax = plt.subplots(figsize=(5, 3))
    x = np.zeros(2000)
    for t in range(1, 2000):
        x[t] = 0.9 * x[t - 1] + r.normal()
    x -= x.mean()
    ac = np.correlate(x, x, "full")[len(x) - 1:][:60] / (x @ x)
    ax.vlines(range(60), 0, ac)
    ax.axhline(0, color="k", lw=0.5)
    ax.set_title("Autocorrelation, AR(1) chain")
    return fig


@plot
def corner_plot(r):
    cov = [[1, 0.8, -0.3], [0.8, 1, -0.1], [-0.3, -0.1, 1]]
    s = r.multivariate_normal([0, 1, 2], cov, 5000)
    names = [r"$\theta_1$", r"$\theta_2$", r"$\theta_3$"]
    fig, axes = plt.subplots(3, 3, figsize=(6, 6))
    for i in range(3):
        for j in range(3):
            ax = axes[i, j]
            if j > i:
                ax.axis("off")
            elif i == j:
                ax.hist(s[:, i], bins=40, histtype="stepfilled", color="C0", alpha=0.6)
                ax.set_yticks([])
            else:
                ax.hist2d(s[:, j], s[:, i], bins=40, cmap="Blues")
            if i == 2:
                ax.set_xlabel(names[j])
            if j == 0 and i > 0:
                ax.set_ylabel(names[i])
    fig.tight_layout()
    return fig


@plot
def pair_scatter(r):
    s = r.multivariate_normal([0, 0, 0, 0], np.eye(4) * 0.5 + 0.5, 400)
    fig, axes = plt.subplots(4, 4, figsize=(6, 6), sharex="col")
    for i in range(4):
        for j in range(4):
            if i == j:
                axes[i, j].hist(s[:, i], bins=20, color="C1")
            else:
                axes[i, j].scatter(s[:, j], s[:, i], s=3, alpha=0.5)
            axes[i, j].tick_params(labelsize=6)
    return fig


@plot
def forest_plot(r):
    k = 12
    est = r.normal(0.3, 0.3, k)
    se = r.uniform(0.1, 0.4, k)
    fig, ax = plt.subplots(figsize=(5, 5))
    y = np.arange(k)[::-1]
    ax.errorbar(est, y, xerr=1.96 * se, fmt="s", color="k", ecolor="0.4", capsize=3)
    pooled = np.sum(est / se**2) / np.sum(1 / se**2)
    ax.axvline(pooled, color="C3", ls="--")
    ax.axvline(0, color="k", lw=0.7)
    ax.fill([pooled - 0.1, pooled, pooled + 0.1, pooled], [-1.5, -1.2, -1.5, -1.8], color="C3")
    ax.set_yticks(list(y) + [-1.5], ["Study %d" % (i + 1) for i in range(k)] + ["Pooled"])
    ax.set_xlabel("log odds ratio")
    return fig


@plot
def posterior_predictive(r):
    x = np.linspace(0, 10, 50)
    y = 1.5 + 0.8 * x + r.normal(0, 1.2, 50)
    fig, ax = plt.subplots(figsize=(5, 3.5))
    for _ in range(60):
        a, b = r.normal(1.5, 0.3), r.normal(0.8, 0.05)
        ax.plot(x, a + b * x, color="C0", alpha=0.08)
    xs = np.linspace(0, 10, 100)
    ax.fill_between(xs, 1.5 + 0.8 * xs - 2.4, 1.5 + 0.8 * xs + 2.4, color="C1", alpha=0.2, label="95% PI")
    ax.scatter(x, y, s=12, color="k", zorder=3, label="data")
    ax.legend(loc="upper left")
    return fig


@plot
def hierarchical_shrinkage(r):
    raw = r.normal(0, 1.5, 15)
    shr = raw * 0.55
    fig, ax = plt.subplots(figsize=(4, 5))
    for a, b in zip(raw, shr):
        ax.plot([0, 1], [a, b], "o-", color="0.5", mfc="w")
    ax.set_xticks([0, 1], ["no pooling", "partial pooling"])
    ax.set_title("Shrinkage")
    return fig


@plot
def prior_sensitivity_grid(r):
    fig, axes = plt.subplots(2, 3, figsize=(7, 4), sharex=True, sharey=True)
    x = np.linspace(0, 1, 200)
    for ax, (a, b) in zip(axes.flat, [(0.5, 0.5), (1, 1), (2, 2), (5, 1), (1, 5), (10, 10)]):
        ax.plot(x, stats.beta.pdf(x, a, b), color="C4")
        ax.plot(x, stats.beta.pdf(x, a + 7, b + 3), color="C0")
        ax.set_title("Beta(%g, %g)" % (a, b), fontsize=9)
    fig.tight_layout()
    return fig


@plot
def gaussian_process(r):
    X = np.sort(r.uniform(0, 10, 8))
    Y = np.sin(X) + r.normal(0, 0.1, 8)
    xs = np.linspace(0, 10, 200)
    k = lambda a, b: np.exp(-0.5 * (a[:, None] - b[None, :]) ** 2)
    K = k(X, X) + 0.01 * np.eye(8)
    Ks = k(xs, X)
    mu = Ks @ np.linalg.solve(K, Y)
    var = 1 - np.sum(Ks * np.linalg.solve(K, Ks.T).T, 1)
    sd = np.sqrt(np.clip(var, 0, None))
    fig, ax = plt.subplots(figsize=(5.5, 3))
    ax.fill_between(xs, mu - 2 * sd, mu + 2 * sd, alpha=0.25)
    ax.plot(xs, mu)
    ax.plot(X, Y, "k+", ms=10)
    ax.set_title(r"GP posterior, $k(x,x') = \exp(-\frac{1}{2}(x-x')^2)$")
    return fig


@plot
def bayes_factor_bars(r):
    fig, ax = plt.subplots(figsize=(5, 3))
    bf = np.exp(r.normal(0, 2, 8))
    ax.bar(range(8), bf, color=["C2" if b > 1 else "C3" for b in bf])
    ax.set_yscale("log")
    ax.axhline(1, color="k")
    ax.set_ylabel(r"$BF_{10}$")
    return fig


@plot
def dirichlet_simplex(r):
    s = r.dirichlet([2, 3, 5], 3000)
    x = s[:, 1] + 0.5 * s[:, 2]
    y = np.sqrt(3) / 2 * s[:, 2]
    fig, ax = plt.subplots(figsize=(4, 3.7))
    ax.plot([0, 1, 0.5, 0], [0, 0, np.sqrt(3) / 2, 0], "k-")
    ax.scatter(x, y, s=1, alpha=0.3)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(r"Dir$(2,3,5)$")
    return fig


@plot
def rank_plot(r):
    fig, axes = plt.subplots(1, 4, figsize=(7, 2.2), sharey=True)
    for ax in axes:
        ax.hist(r.integers(0, 1000, 1000), bins=20, color="C0", edgecolor="w")
    fig.suptitle("Rank plots")
    return fig


# ---------------------------------------------------------------- classic stats
@plot
def histogram_kde(r):
    s = np.concatenate([r.normal(0, 1, 500), r.normal(4, 0.7, 300)])
    fig, ax = plt.subplots(figsize=(5, 3))
    ax.hist(s, bins=40, density=True, alpha=0.5, edgecolor="k", lw=0.3)
    xs = np.linspace(-4, 7, 300)
    ax.plot(xs, stats.gaussian_kde(s)(xs), "k")
    return fig


@plot
def stacked_hist(r):
    fig, ax = plt.subplots(figsize=(5, 3))
    ax.hist([r.normal(m, 1, 300) for m in (0, 1, 2)], bins=25, stacked=True, label=["A", "B", "C"])
    ax.legend()
    return fig


@plot
def contour_density(r):
    x, y = np.mgrid[-3:3:120j, -3:3:120j]
    z = np.exp(-(x**2 + y**2 - 1.2 * x * y)) + 0.5 * np.exp(-((x - 1.5) ** 2 + (y + 1) ** 2) * 3)
    fig, ax = plt.subplots(figsize=(4.5, 4))
    cs = ax.contour(x, y, z, 10, cmap="viridis")
    ax.clabel(cs, fontsize=7)
    return fig


@plot
def contourf_colorbar(r):
    x, y = np.mgrid[-2:2:150j, -2:2:150j]
    z = np.sin(3 * x) * np.cos(2 * y) + 0.3 * x
    fig, ax = plt.subplots(figsize=(5, 4))
    cf = ax.contourf(x, y, z, 15, cmap="RdBu_r")
    fig.colorbar(cf, ax=ax, label="f(x, y)")
    return fig


@plot
def heatmap_annot(r):
    m = np.corrcoef(r.normal(size=(8, 50)))
    fig, ax = plt.subplots(figsize=(5, 4.5))
    im = ax.imshow(m, cmap="coolwarm", vmin=-1, vmax=1)
    for i in range(8):
        for j in range(8):
            ax.text(j, i, "%.2f" % m[i, j], ha="center", va="center", fontsize=6)
    fig.colorbar(im)
    return fig


@plot
def pcolormesh_grid(r):
    z = r.random((12, 18))
    fig, ax = plt.subplots(figsize=(5, 3.5))
    ax.pcolormesh(z, cmap="magma", edgecolors="w", linewidth=0.3)
    return fig


@plot
def hexbin_density(r):
    x = r.standard_normal(4000)
    y = x * 0.5 + r.standard_normal(4000)
    fig, ax = plt.subplots(figsize=(5, 4))
    hb = ax.hexbin(x, y, gridsize=25, cmap="inferno")
    fig.colorbar(hb)
    return fig


@plot
def roc_curves(r):
    fig, ax = plt.subplots(figsize=(4, 4))
    for d in (0.5, 1.0, 2.0):
        t = np.linspace(-5, 7, 200)
        ax.plot(stats.norm.sf(t), stats.norm.sf(t, d), label="d'=%.1f" % d)
    ax.plot([0, 1], [0, 1], "k:")
    ax.set_xlabel("FPR")
    ax.set_ylabel("TPR")
    ax.legend(loc="lower right")
    ax.set_aspect("equal")
    return fig


@plot
def precision_recall(r):
    fig, ax = plt.subplots(figsize=(4, 3.5))
    rec = np.linspace(0, 1, 50)
    ax.step(rec, 1 - 0.5 * rec**2 + r.normal(0, 0.02, 50), where="post")
    ax.set_xlabel("Recall")
    ax.set_ylabel("Precision")
    return fig


@plot
def errorbars(r):
    x = np.arange(1, 9)
    fig, ax = plt.subplots(figsize=(5, 3))
    ax.errorbar(x, x**0.5 + r.normal(0, 0.1, 8), yerr=r.uniform(0.1, 0.3, 8), fmt="o-", capsize=4, label="A")
    ax.errorbar(x + 0.1, x**0.4, yerr=[r.uniform(0.05, 0.2, 8), r.uniform(0.1, 0.4, 8)], fmt="s--", capsize=2, label="B")
    ax.legend()
    return fig


@plot
def log_axes(r):
    x = np.logspace(0, 5, 60)
    fig, ax = plt.subplots(figsize=(5, 3.5))
    ax.loglog(x, x**-1.5 * (1 + r.normal(0, 0.1, 60)), "o", ms=3)
    ax.loglog(x, x**-1.5, "k-")
    ax.grid(True, which="both", ls=":", lw=0.5)
    ax.set_xlabel(r"$k$")
    ax.set_ylabel(r"$P(k) \propto k^{-3/2}$")
    return fig


@plot
def semilog_decay(r):
    t = np.linspace(0, 10, 100)
    fig, ax = plt.subplots(figsize=(5, 3))
    for k in (0.3, 0.7, 1.5):
        ax.semilogy(t, np.exp(-k * t), label=r"$e^{-%.1ft}$" % k)
    ax.legend()
    return fig


@plot
def boxplot_violin(r):
    data = [r.normal(m, s, 200) for m, s in [(0, 1), (1, 0.5), (0.5, 2), (2, 1)]]
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(7, 3))
    a1.boxplot(data, notch=True)
    a2.violinplot(data, showmedians=True)
    return fig


@plot
def qq_plot(r):
    s = np.sort(r.standard_t(4, 300))
    q = stats.norm.ppf((np.arange(300) + 0.5) / 300)
    fig, ax = plt.subplots(figsize=(4, 4))
    ax.plot(q, s, ".")
    ax.plot([-3, 3], [-3, 3], "r-")
    ax.set_title("Q-Q plot, $t_4$ vs normal")
    return fig


@plot
def regression_residuals(r):
    x = r.uniform(0, 10, 80)
    y = 2 + 0.5 * x + r.normal(0, 1, 80)
    b = np.polyfit(x, y, 1)
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(5, 4.5), sharex=True, gridspec_kw={"height_ratios": [2, 1]})
    a1.scatter(x, y, s=10)
    a1.plot([0, 10], np.polyval(b, [0, 10]), "k")
    a2.scatter(x, y - np.polyval(b, x), s=10, color="C1")
    a2.axhline(0, color="k", lw=0.5)
    return fig


@plot
def ecdf(r):
    fig, ax = plt.subplots(figsize=(5, 3))
    for i in range(3):
        s = np.sort(r.normal(i * 0.5, 1, 100))
        ax.step(s, np.arange(1, 101) / 100, where="post")
    return fig


@plot
def bar_groups(r):
    fig, ax = plt.subplots(figsize=(5.5, 3))
    w = 0.25
    for i in range(3):
        ax.bar(np.arange(5) + i * w, r.uniform(1, 5, 5), w, yerr=r.uniform(0.1, 0.5, 5), capsize=2, label="group %d" % i)
    ax.set_xticks(np.arange(5) + w, list("ABCDE"))
    ax.legend(ncol=3)
    return fig


@plot
def horizontal_bar(r):
    fig, ax = plt.subplots(figsize=(5, 3.5))
    v = np.sort(r.uniform(0, 1, 10))
    ax.barh(["feature %d" % i for i in range(10)], v, color=plt.cm.viridis(v))
    return fig


@plot
def pie_donut(r):
    fig, ax = plt.subplots(figsize=(4, 4))
    ax.pie([35, 25, 20, 12, 8], labels=list("ABCDE"), autopct="%1.0f%%", wedgeprops={"width": 0.45, "edgecolor": "w"})
    return fig


@plot
def polar_rose(r):
    fig = plt.figure(figsize=(4, 4))
    ax = fig.add_subplot(projection="polar")
    th = np.linspace(0, 2 * np.pi, 400)
    ax.plot(th, np.abs(np.cos(4 * th)))
    ax.bar(np.linspace(0, 2 * np.pi, 16, endpoint=False), r.uniform(0.2, 1, 16), width=0.35, alpha=0.4)
    return fig


@plot
def quiver_field(r):
    x, y = np.meshgrid(np.linspace(-2, 2, 15), np.linspace(-2, 2, 15))
    fig, ax = plt.subplots(figsize=(4.5, 4.5))
    ax.quiver(x, y, -y, x - 0.3 * y, np.hypot(x, y), cmap="plasma")
    return fig


@plot
def streamplot_field(r):
    y, x = np.mgrid[-3:3:60j, -3:3:60j]
    fig, ax = plt.subplots(figsize=(4.5, 4.5))
    ax.streamplot(x, y, -1 - x**2 + y, 1 + x - y**2, color=np.hypot(x, y), cmap="autumn", density=1.2)
    return fig


@plot
def surface_3d(r):
    fig = plt.figure(figsize=(5, 4))
    ax = fig.add_subplot(projection="3d")
    x, y = np.meshgrid(np.linspace(-3, 3, 30), np.linspace(-3, 3, 30))
    ax.plot_surface(x, y, np.sin(np.hypot(x, y)), cmap="viridis", linewidth=0)
    return fig


@plot
def wireframe_3d(r):
    fig = plt.figure(figsize=(5, 4))
    ax = fig.add_subplot(projection="3d")
    x, y = np.meshgrid(np.linspace(-2, 2, 20), np.linspace(-2, 2, 20))
    ax.plot_wireframe(x, y, np.exp(-(x**2 + y**2)), rstride=1, cstride=1, lw=0.5)
    return fig


@plot
def mathtext_showcase(r):
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.axis("off")
    eqs = [
        r"$\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}$",
        r"$p(\theta \mid y) = \frac{p(y \mid \theta)\,p(\theta)}{\int p(y \mid \theta')\,p(\theta')\,d\theta'}$",
        r"$\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$",
        r"$\mathcal{N}(\mu, \sigma^2),\ \hat{\beta} = (X^\top X)^{-1} X^\top y$",
        r"$\mathbb{E}[X] = \sum_i x_i\,P(X = x_i),\quad \alpha\beta\gamma\delta\epsilon$",
    ]
    for i, e in enumerate(eqs):
        ax.text(0.02, 0.9 - i * 0.2, e, fontsize=13)
    return fig


@plot
def sine_cosine_basic(r):
    x = np.linspace(0, 2 * np.pi, 200)
    fig, ax = plt.subplots(figsize=(5, 3))
    ax.plot(x, np.sin(x), label=r"$\sin x$")
    ax.plot(x, np.cos(x), "--", label=r"$\cos x$")
    ax.set_xticks([0, np.pi / 2, np.pi, 3 * np.pi / 2, 2 * np.pi], ["0", r"$\pi/2$", r"$\pi$", r"$3\pi/2$", r"$2\pi$"])
    ax.legend()
    ax.grid(alpha=0.3)
    return fig


@plot
def time_series_bands(r):
    t = np.arange(200)
    y = np.cumsum(r.normal(0, 1, 200))
    fig, ax = plt.subplots(figsize=(6, 3))
    ax.plot(t, y, lw=0.8)
    for w in (1, 2):
        ax.fill_between(t[150:], y[149] - w * np.sqrt(t[150:] - 149), y[149] + w * np.sqrt(t[150:] - 149), alpha=0.15, color="C1")
    ax.axvline(150, color="k", ls=":")
    return fig


@plot
def scatter_colormap_sizes(r):
    fig, ax = plt.subplots(figsize=(5, 4))
    sc = ax.scatter(r.random(150), r.random(150), c=r.random(150), s=r.random(150) * 200, alpha=0.6, cmap="Spectral", edgecolors="k", linewidths=0.3)
    fig.colorbar(sc)
    return fig


@plot
def markers_linestyles(r):
    fig, ax = plt.subplots(figsize=(5.5, 3.5))
    for i, (m, ls) in enumerate(zip("os^vD*xP+h", ["-", "--", "-.", ":", (0, (5, 1)), (0, (1, 3)), "-", "--", "-.", ":"])):
        ax.plot(np.arange(6), i + 0.3 * np.sin(np.arange(6) + i), marker=m, ls=ls)
    return fig


@plot
def image_colormap(r):
    x, y = np.meshgrid(np.linspace(-2, 1, 200), np.linspace(-1.5, 1.5, 200))
    c = x + 1j * y
    z = np.zeros_like(c)
    n = np.zeros(c.shape)
    for _ in range(30):
        z = np.where(np.abs(z) < 2, z * z + c, z)
        n += np.abs(z) < 2
    fig, ax = plt.subplots(figsize=(4, 4))
    ax.imshow(n, cmap="twilight", extent=(-2, 1, -1.5, 1.5))
    return fig


@plot
def twin_axes(r):
    t = np.linspace(0, 10, 100)
    fig, ax = plt.subplots(figsize=(5, 3))
    ax.plot(t, np.exp(t / 3), "C0")
    ax2 = ax.twinx()
    ax2.plot(t, np.sin(t), "C1")
    ax.set_ylabel("exp", color="C0")
    ax2.set_ylabel("sin", color="C1")
    return fig


@plot
def annotated_arrows(r):
    x = np.linspace(-2, 2, 200)
    fig, ax = plt.subplots(figsize=(5, 3.5))
    ax.plot(x, x**3 - x)
    ax.annotate("local max", xy=(-0.577, 0.385), xytext=(-1.8, 1.5), arrowprops=dict(arrowstyle="->", connectionstyle="arc3,rad=.3"))
    ax.annotate("local min", xy=(0.577, -0.385), xytext=(1, -2), arrowprops=dict(facecolor="k", shrink=0.05, width=1))
    ax.spines[["top", "right"]].set_visible(False)
    return fig


@plot
def subplots_grid_mixed(r):
    fig = plt.figure(figsize=(7, 5))
    gs = fig.add_gridspec(2, 3)
    fig.add_subplot(gs[0, :2]).plot(np.cumsum(r.normal(size=100)))
    fig.add_subplot(gs[0, 2]).pie([1, 2, 3])
    fig.add_subplot(gs[1, 0]).hist(r.normal(size=300))
    fig.add_subplot(gs[1, 1:]).scatter(r.random(50), r.random(50))
    fig.tight_layout()
    return fig


@plot
def fill_between_regions(r):
    x = np.linspace(0, 4 * np.pi, 300)
    y1, y2 = np.sin(x), 0.5 * np.cos(1.5 * x)
    fig, ax = plt.subplots(figsize=(5.5, 3))
    ax.fill_between(x, y1, y2, where=y1 > y2, color="C2", alpha=0.5, interpolate=True)
    ax.fill_between(x, y1, y2, where=y1 <= y2, color="C3", alpha=0.5, interpolate=True, hatch="//")
    return fig


@plot
def hatch_bars(r):
    fig, ax = plt.subplots(figsize=(5, 3))
    for i, h in enumerate(["/", "\\\\", "x", "o", ".", "*", "-", "+"]):
        ax.bar(i, 1 + i * 0.2, hatch=h, fill=False, edgecolor="C%d" % i)
    return fig


@plot
def normal_distributions(r):
    x = np.linspace(-5, 5, 400)
    fig, ax = plt.subplots(figsize=(5, 3))
    for mu, s in [(0, 0.5), (0, 1), (0, 2), (-2, 0.7)]:
        ax.plot(x, stats.norm.pdf(x, mu, s), label=r"$\mu=%g,\ \sigma^2=%g$" % (mu, s**2))
    ax.legend(fontsize=8)
    return fig


@plot
def poisson_pmf(r):
    k = np.arange(0, 20)
    fig, ax = plt.subplots(figsize=(5, 3))
    for i, lam in enumerate((1, 4, 10)):
        ax.plot(k, stats.poisson.pmf(k, lam), "o-", ms=4, label=r"$\lambda=%d$" % lam)
    ax.legend()
    return fig


@plot
def ridge_plot(r):
    fig, ax = plt.subplots(figsize=(5, 5))
    xs = np.linspace(-4, 8, 300)
    for i in range(8):
        d = stats.gaussian_kde(r.normal(i * 0.5, 1 + 0.1 * i, 300))(xs)
        ax.fill_between(xs, i, i + d * 3, color=plt.cm.viridis(i / 8), alpha=0.8, zorder=10 - i)
        ax.plot(xs, i + d * 3, "w", lw=0.8, zorder=10 - i)
    ax.set_yticks([])
    return fig


@plot
def confusion_matrix(r):
    m = np.array([[50, 3, 2], [4, 40, 6], [1, 5, 44]])
    fig, ax = plt.subplots(figsize=(4, 3.5))
    ax.imshow(m, cmap="Greens")
    for i in range(3):
        for j in range(3):
            ax.text(j, i, m[i, j], ha="center", va="center", color="w" if m[i, j] > 30 else "k")
    ax.set_xticks(range(3), ["cat", "dog", "bird"])
    ax.set_yticks(range(3), ["cat", "dog", "bird"])
    return fig


@plot
def dendrogram_like(r):
    from scipy.cluster.hierarchy import dendrogram, linkage

    fig, ax = plt.subplots(figsize=(6, 3))
    dendrogram(linkage(r.normal(size=(20, 3)), "ward"), ax=ax)
    return fig


@plot
def phase_portrait(r):
    fig, ax = plt.subplots(figsize=(4.5, 4.5))
    for x0 in np.linspace(-2, 2, 7):
        for y0 in (-2, 2):
            x, y = x0, y0
            path = []
            for _ in range(300):
                x, y = x + 0.02 * y, y + 0.02 * (-x - 0.3 * y + 0.0 * x**3)
                path.append((x, y))
            p = np.array(path)
            ax.plot(p[:, 0], p[:, 1], lw=0.8)
    return fig


STYLES = ["default", "ggplot", "bmh", "seaborn-v0_8-whitegrid", "dark_background", "classic", "fivethirtyeight", "grayscale"]
# plots rendered again in a non-default style (index into PLOTS -> style)
STYLE_VARIANTS = {0: "ggplot", 3: "bmh", 5: "seaborn-v0_8-whitegrid", 8: "dark_background", 15: "classic",
                  19: "fivethirtyeight", 22: "grayscale", 24: "ggplot", 29: "bmh", 40: "dark_background"}
# every Nth plot also rendered with svg.fonttype='none'
TEXT_EVERY = 3


def render(fn, style, fonttype, dest):
    with plt.style.context(style):
        plt.rcParams["svg.hashsalt"] = "lean-svg-T103"
        plt.rcParams["svg.fonttype"] = fonttype
        fig = fn(np.random.default_rng(sum(map(ord, fn.__name__)) * 7919))
        fig.savefig(dest, metadata={"Date": None}, bbox_inches="tight")
        plt.close(fig)


def main():
    (OUT / "matplotlib").mkdir(exist_ok=True)
    (OUT / "matplotlib-text").mkdir(exist_ok=True)
    n = 0
    for i, fn in enumerate(PLOTS):
        render(fn, "default", "path", OUT / "matplotlib" / (fn.__name__ + ".svg"))
        n += 1
        if i in STYLE_VARIANTS:
            st = STYLE_VARIANTS[i]
            render(fn, st, "path", OUT / "matplotlib" / ("%s__%s.svg" % (fn.__name__, st.replace("seaborn-v0_8-", "sns-"))))
            n += 1
        if i % TEXT_EVERY == 0:
            render(fn, "default", "none", OUT / "matplotlib-text" / (fn.__name__ + ".svg"))
            n += 1
    print("matplotlib: %d SVGs from %d plots" % (n, len(PLOTS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/bin/sh
# Rebuild the IEEE-style block diagrams (TikZ) as PDF and 300-dpi PNG.
# Needs: pdflatex (TeX Live with tikz, standalone), pdftoppm (poppler).
set -e
cd "$(dirname "$0")"
for f in fig*.tex; do
  pdflatex -interaction=nonstopmode -halt-on-error "$f" > /dev/null
  b="${f%.tex}"
  pdftoppm -png -r 300 -singlefile "$b.pdf" "../figures/$b"
done
rm -f *.aux *.log
echo "Diagrams written to docs/figures/"

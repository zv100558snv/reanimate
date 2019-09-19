#!/usr/bin/env bash

EXAMPLES='boundingbox colormaps goo latex_basic latex_color latex_draw
          latex_wheel raster sphere sunflower tangent_and_normal vector_field'

WIDTH=640
HEIGHT=$((WIDTH*9/16))
FPS=30

SRC_DIR=examples
DST_DIR=docs/rendered
OPTS='--fps $FPS --width $WIDTH --height $HEIGHT'

cat << EOF > docs/gallery.md
# Gallery
This file is auto-generated by docs/render_all.sh. DO NOT EDIT.

EOF

for e in $EXAMPLES; do
  cat << EOF >> docs/gallery.md
## $e

<details>
  <summary>View $e.hs</summary>
  <pre><code class="haskell">
  {!examples/$e.hs!}
  </code></pre>
</details>
<br/>
<video width="$WIDTH" height="$HEIGHT" autoplay loop>
  <source src="https://github.com/Lemmih/reanimate/raw/master/docs/rendered/$e.mp4">
</video>

<br/><hr><br/>

EOF

  SRC_FILE=./$SRC_DIR/$e.hs
  DST_FILE=./$DST_DIR/$e.mp4
  if [[ "$SRC_FILE" -nt "$DST_FILE" ]]; then
    stack $SRC_FILE render --compile -o $DST_FILE $OPTS
  fi
done
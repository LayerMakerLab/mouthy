#!/bin/bash
# Training on one GPU, one model after the other: Mouthy's acoustic model to 150k steps, then its vocoder.
cd "${MOUTHY_VOICE_DIR:-$HOME/mouthy-voice}" && source env.sh   # the work folder described in README.md; env.sh sets its paths
.venv/bin/python Matcha-TTS/matcha/train.py experiment=mouthy +trainer.max_steps=150000 test=False ${MATCHA_RESUME:+ckpt_path=$MATCHA_RESUME} > logs/matcha.log 2>&1
status=$?; echo "matcha exit $status at $(date)" >> logs/pipeline.log
[ $status -eq 0 ] || exit $status
.venv-vocos/bin/python vocos/train.py -c vocos/configs/mouthy-vocos.yaml > logs/vocos.log 2>&1
echo "vocos exit $? at $(date)" >> logs/pipeline.log

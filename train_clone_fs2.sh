taskid=${1}
echo "task id is $taskid"

CORE_DATASET=/dltraining/datasets/libritts
DATASET_DIR=/dltraining/datasets_$taskid
OUTDIR=/dltraining/outdir_$taskid
CKPT_DIR=$OUTDIR/checkpoints
libritts=$DATASET_DIR/libritts
dump=$DATASET_DIR/dump_libritts
fs2_yaml=examples/fastspeech2_libritts/conf/fastspeech2libritts_clone.yaml

mkdir "$DATASET_DIR"
mkdir "$libritts"

gpus=$(nvidia-smi --query-gpu=index --format=csv,noheader | paste -s -d',')
echo "gpus = $gpus"

latestCkptPath=$(ls -t $CKPT_DIR/ckpt-*index | head -1)
ckptExists=false
latestCkpt="NA"
if [[ $latestCkptPath == *"index" ]]; 
then
        latestCkpt="$( echo "$latestCkptPath" | sed -e 's#.index$##' )"
        ckptExists=true
fi
echo "latest checkpoint is $latestCkptPath"

if [[ $ckptExists == true ]]; 
then
  echo "RESUMING from checkpoint $latestCkpt"
  CUDA_VISIBLE_DEVICES=$gpus python examples/fastspeech2_libritts/train_fastspeech2.py \
      --train-dir $dump/train/ \
      --dev-dir $dump/valid/ \
      --outdir $OUTDIR/ \
      --config $fs2_yaml \
      --use-norm 1 \
      --f0-stat $dump/stats_f0.npy \
      --energy-stat $dump/stats_energy.npy \
      --mixed_precision 1 \
      --dataset_mapping $dump/libritts_mapper.json \
      --dataset_config preprocess/libritts_preprocess.yaml \
      --dataset_stats $dump/stats.npy \
      --resume "$latestCkpt"
else
  python setupCloneDataset.py --task_id=$taskid --libri_path=$libritts --dataset_path=$CORE_DATASET --for_vocoder='false'
  numSpeakers=$(ls $libritts|wc -l)
  echo "$numSpeakers found in libritts"
  
  rm -rf mfa
  rm -rf /home/ubuntu/Documents
  rm -rf $dump
  
  ./examples/mfa_extraction/scripts/prepare_mfa.sh

  python examples/mfa_extraction/run_mfa.py \
  --corpus_directory $libritts \
  --output_directory ./mfa/parsed \
  --jobs 8

  python examples/mfa_extraction/txt_grid_parser.py \
  --yaml_path $fs2_yaml \
  --dataset_path $libritts \
  --text_grid_path ./mfa/parsed \
  --output_durations_path $libritts/durations \
  --sample_rate 24000

  tensorflow-tts-preprocess --rootdir $libritts \
  --outdir $dump \
  --config preprocess/libritts_preprocess.yaml \
  --dataset libritts

  tensorflow-tts-normalize --rootdir $dump \
  --outdir $dump \
  --config preprocess/libritts_preprocess.yaml \
  --dataset libritts

  python examples/mfa_extraction/fix_mismatch.py \
  --base_path $dump \
  --trimmed_dur_path $libritts/trimmed-durations \
  --dur_path $libritts/durations
  
  pretrainedFile=/dltraining/datasets/pretrained_fs2-184-150k.h5
  if [ ! -f $pretrainedFile ]; then
      echo "Downloading pretrained fs2 from s3"
      aws s3 cp s3://murf-models-dev/pretrained/fs2-184-150k.h5 $pretrainedFile
  fi

  echo "Using PRETRAINED from model $pretrainedFile"
  CUDA_VISIBLE_DEVICES=$gpus python examples/fastspeech2_libritts/train_fastspeech2.py \
      --train-dir $dump/train/ \
      --dev-dir $dump/valid/ \
      --outdir $OUTDIR/ \
      --config $fs2_yaml \
      --use-norm 1 \
      --f0-stat $dump/stats_f0.npy \
      --energy-stat $dump/stats_energy.npy \
      --mixed_precision 1 \
      --dataset_mapping $dump/libritts_mapper.json \
      --dataset_config preprocess/libritts_preprocess.yaml \
      --dataset_stats $dump/stats.npy \
      --pretrained $pretrainedFile
fi

latestModelPath=$(ls -t $CKPT_DIR/model-*h5 | head -1)
modelExists=false
if [[ $latestmodelPath == *"h5" ]]; 
then
  modelExists=true
fi
echo "latest model is $latestModelPath"

if [[ $modelExists == true ]]; 
then
  aws s3 cp "$OUTDIR/config.yml" "s3://murf-models-dev/trained/$taskid/config.yml"
  aws s3 cp "$latestModelPath" "s3://murf-models-dev/trained/$taskid/model.h5"
fi


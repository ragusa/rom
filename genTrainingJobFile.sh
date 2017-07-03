NF=256
CORRLENGTH=0.08
NTRAIN=4
NSTART=1	#First training data sample in data file
VOLFRAC=-1	#Theoretical volume fraction; -1 for uniform random volume fraction
LOCOND=1
HICOND=10
HYPERPARAM=0.4	#Lasso sparsity hyperparameter
NCX=\[.125\ .125\ .125\ .125\ .125\ .125\ .125\ .125\]
NCY=\[.125\ .125\ .125\ .125\ .125\ .125\ .125\ .125\]
BC="[0 1000 0 0]"
BC2=\[0\ 1000\ 0\ 0\]

NAMEBASE="RVM"
DATESTR=`date +%m-%d-%H-%M-%S`	#datestring for jobfolder name
PROJECTDIR="/home/constantin/matlab/projects/rom"
JOBNAME="${NAMEBASE}_nTrain=${NTRAIN}_Nc=${NCX}_${NCY}"
JOBDIR="/home/constantin/matlab/data/fineData/systemSize=${NF}x${NF}/correlated_binary/IsoSEcov/l=${CORRLENGTH}_sigmafSq=1/volumeFraction=${VOLFRAC}/locond=${LOCOND}_upcond=${HICOND}/BCcoeffs=${BC2}/${NAMEBASE}_nTrain=${NTRAIN}_Nc=${NCX}_${NCY}_${DATESTR}"

#Create job directory and copy source code
mkdir "${JOBDIR}"
cp -r $PROJECTDIR/* "$JOBDIR"
#Remove existing data folder
rm -r $PROJECTDIR/data
#Remove existing predictions file
rm $PROJECTDIR/predictions.mat
#Change directory to job directory; completely independent from project directory
cd "$JOBDIR"
CWD=$(printf "%q\n" "$(pwd)")
rm job_file.sh

#write job file
printf "#PBS -N $JOBNAME
#PBS -l nodes=1:ppn=4,walltime=240:00:00
#PBS -e /home/constantin/OEfiles
#PBS -o /home/constantin/OEfiles
#PBS -m abe
#PBS -M mailscluster@gmail.com

#Switch to job directory
cd \"$JOBDIR\"
#Set parameters
sed -i \"33s/.*/        nStart = $NSTART;             %%first training data sample in file/\" ./ROM_SPDE.m
sed -i \"34s/.*/        nTrain = $NTRAIN;            %%number of samples used for training/\" ./ROM_SPDE.m
sed -i \"70s/.*/theta_prior_hyperparamArray = [$HYPERPARAM];/\" ./params/params.m
sed -i \"7s/.*/        nElFX = $NF;/\" ./ROM_SPDE.m
sed -i \"8s/.*/        nElFY = $NF;/\" ./ROM_SPDE.m
sed -i \"77s/.*/        boundaryConditions = '$BC';/\" ./ROM_SPDE.m
sed -i \"10s/.*/        lowerConductivity = $LOCOND;/\" ./ROM_SPDE.m
sed -i \"11s/.*/        upperConductivity = $HICOND;/\" ./ROM_SPDE.m
sed -i \"74s/.*/        conductivityDistributionParams = {$VOLFRAC [$CORRLENGTH $CORRLENGTH] 1};      %%for correlated_binary:/\" ./ROM_SPDE.m
sed -i \"81s/.*/        coarseGridVectorX = $NCX;/\" ./ROM_SPDE.m
sed -i \"82s/.*/        coarseGridVectorY = $NCY;/\" ./ROM_SPDE.m


#Run Matlab
/home/matlab/R2017a/bin/matlab -nodesktop -nodisplay -nosplash -r \"trainModel ; quit;\"" >> job_file.sh

chmod +x job_file.sh
#directly submit job file
qsub job_file.sh
#./job_file.sh	#to test in shell


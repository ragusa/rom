%Computes distance from test sample to training data mean


%Which data to load? We will get error if data doesn't exist
nf = 256;
loCond = 1;
upCond = 10;
nSamplesTrain = 1024;
nSamplesTest = 128;
corrlength = '10';
volfrac = '0.1';  %high conducting phase volume fraction
sigma_f2 = '1';
cond_distribution = 'correlated_binary';
bc = '[-50 164 112 -30]';

%Prediction settings
nStart = 1;
nTrain = 256;
nTest = 128;



%Folder where finescale data is saved
fineDataPath = '~/matlab/data/fineData/';
%System size
fineDataPath = strcat(fineDataPath, 'systemSize=', num2str(nf), 'x', num2str(nf), '/');
%Type of conductivity distribution
if strcmp(cond_distribution, 'correlated_binary')
    fineDataPath = strcat(fineDataPath, cond_distribution, '/', 'IsoSEcov/', 'l=',...
        corrlength, '_sigmafSq=', sigma_f2, '/volumeFraction=',...
        volfrac, '/', 'locond=', num2str(loCond),...
        '_upcond=', num2str(upCond), '/', 'BCcoeffs=', bc, '/');
elseif strcmp(cond_distribution, 'binary')
    fineDataPath = strcat(fineDataPath, cond_distribution, '/volumeFraction=',...
        volfrac, '/', 'locond=', num2str(loCond),...
        '_upcond=', num2str(upCond), '/', 'BCcoeffs=', bc, '/');
else
    error('Unknown conductivity distribution')
end
clear nf corrlength volfrac sigma_f2 cond_distribution bc;

%Name of training data file
trainFileName = strcat(fineDataPath, 'set1-samples=', num2str(nSamplesTrain), '.mat');
testFileName = strcat(fineDataPath, 'set2-samples=', num2str(nSamplesTest), '.mat');
trainFile = matfile(trainFileName);
testFile = matfile(testFileName);


trainMean = mean(trainFile.Tf(:, nStart:(nStart + nTrain - 1)), 2);
T_test = testFile.Tf(:, 1:nTest);

sqDist = 0;
for i = 1:nTest
    sqDist = ((i - 1)/i)*sqDist + (1/i)*mean((trainMean - T_test(:, i)).^2);  
end
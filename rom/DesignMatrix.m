classdef DesignMatrix
    %Class describing the design matrices Phi for different data points
    
    properties
        
        designMatrices          %Design matrices stored in cells
        
        dataFile                %mat file holding the training/test data
        dataSamples             %vector with data sample indices
        
        featureFunctions        %Cell array of handles to feature functions
        featureFunctionMean  %mean absolute output of feature function over training set BEFORE normalization
        featureFunctionSqMean
        featureFunctionStd
        featureFunctionMin
        featureFunctionMax
        
        E                       %gives the coarse element a fine element belongs to
        EMat                    %fine to coarse index map as a matrix
        lambdak
        xk
        sumPhiTPhi
        
        neighborDictionary      %This array holds the index of theta, the corresponding feature function number, coarse element and neighboring number
        
    end
    
    methods
        
        %constructor
        function Phi = DesignMatrix(domainf, domainc, featureFunctions, dataFile, dataSamples)
            %Set up mapping from fine to coarse element
            Phi = getCoarseElement(Phi, domainc, domainf);
            Phi.featureFunctions = featureFunctions;
            Phi.dataFile = dataFile;
            Phi.dataSamples = dataSamples;
            
        end
        
        function Phi = getCoarseElement(Phi, domainc, domainf)
            Phi.E = zeros(domainf.nEl, 1);
            e = 1;  %element number
            for row_fine = 1:domainf.nElY
                %coordinate of lower boundary of fine element
                y_coord = domainf.cum_lElY(row_fine);
                row_coarse = sum(y_coord >= domainc.cum_lElY);
                for col_fine = 1:domainf.nElX
                    %coordinate of left boundary of fine element
                    x_coord = domainf.cum_lElX(col_fine);
                    col_coarse = sum(x_coord >= domainc.cum_lElX);
                    Phi.E(e) = (row_coarse - 1)*domainc.nElX + col_coarse;
                    e = e + 1;
                end
            end
            
            Phi.EMat = reshape(Phi.E, domainf.nElX, domainf.nElY);
            pltFineToCoarse = false;
            if pltFineToCoarse
                figure
                imagesc(Phi.EMat)
                pause
            end
        end
        
        function Phi = computeDesignMatrix(Phi, nElc, nElf, condTransOpts, mode)
            %Actual computation of design matrix
            tic
            disp('Compute design matrices Phi...')
            
            %load finescale conductivity field
            conductivity = Phi.dataFile.cond(:, Phi.dataSamples);
            conductivity = num2cell(conductivity, 1);   %to avoid parallelization communication overhead
            nTrain = length(Phi.dataSamples);
            nFeatureFunctions = numel(Phi.featureFunctions);
            phi = Phi.featureFunctions;
            coarseElement = Phi.E;
            
            %Open parallel pool
            addpath('./computation')
            parPoolInit(nTrain);
            if condTransOpts.anisotropy
                PhiCell{1} = zeros(3*nElc, nFeatureFunctions);
            else
                PhiCell{1} = zeros(nElc, nFeatureFunctions);
            end
            PhiCell = repmat(PhiCell, nTrain, 1);
%             parfor s = 1:nTrain
            for s = 1:nTrain    %for very cheap features, serial evaluation might be more efficient
                %inputs belonging to same coarse element are in the same column of xk. They are ordered in
                %x-direction.
                if condTransOpts.anisotropy
                    PhiCell{s} = zeros(3*nElc, nFeatureFunctions);
                else
                    PhiCell{s} = zeros(nElc, nFeatureFunctions);
                end
                
                if strcmp(mode, 'global')
                    %ATTENTION: ONLY VALID FOR SQUARE MESHES!!!
                    pooledImage = phi{1}(reshape(conductivity{s}, sqrt(nElf), sqrt(nElf)));
                    pooledImage = pooledImage(:)';
                    npi = numel(pooledImage);
                    PhiCell{s} = zeros(nElc, npi*nElc);
                    for i = 1:nElc
                        PhiCell{s}(i, ((i - 1)*npi + 1):(i*npi)) = pooledImage;
                    end
                else
                    %only for square finescale meshes!!
                    conductivityMat = reshape(conductivity{s}, sqrt(nElf), sqrt(nElf));
                    for i = 1:nElc
                        indexMat = (Phi.EMat == i);
                        lambdakTemp = conductivityMat.*indexMat;
                        %Cut elements from matrix that do not belong to coarse cell
                        lambdakTemp(~any(lambdakTemp, 2), :) = [];
                        lambdakTemp(:, ~any(lambdakTemp, 1)) = [];
                        Phi.lambdak{s, i} = lambdakTemp;
%                         Phi.lambdak{s, i} = conductivity{s}(coarseElement == i);
                        Phi.xk{s, i} = log(Phi.lambdak{s, i});
                    end
                    
                    %construct design matrix Phi
                    for i = 1:nElc
                        for j = 1:nFeatureFunctions
                            %only take pixels of corresponding macro-cell as input for features
                            if condTransOpts.anisotropy
                                PhiCell{s}((1 + (i - 1)*3):(i*3), j) = phi{j}(Phi.lambdak{s, i});
                            else
                                PhiCell{s}(i, j) = phi{j}(Phi.lambdak{s, i});
                            end
                        end
                    end
                end
            end
            
            Phi.designMatrices = PhiCell;
            %Check for real finite inputs
            for i = 1:nTrain
                if(~all(all(all(isfinite(Phi.designMatrices{i})))))
                    dataPoint = i
                    [coarseElement, featureFunction] = ind2sub(size(Phi.designMatrices{i}),...
                        find(~isfinite(Phi.designMatrices{i})))
                    warning('Non-finite design matrix Phi. Setting non-finite component to 0.')
                    Phi.designMatrices{i}(~isfinite(Phi.designMatrices{i})) = 0;
                elseif(~all(all(all(isreal(Phi.designMatrices{i})))))
                    warning('Complex feature function output:')
                    dataPoint = i
                    [coarseElement, featureFunction] = ind2sub(size(Phi.designMatrices{i}),...
                        find(imag(Phi.designMatrices{i})))
                    disp('Ignoring imaginary part...')
                    Phi.designMatrices{i} = real(Phi.designMatrices{i});
                end
            end
            disp('done')
            Phi_computation_time = toc
            
        end
        
        function Phi = includeNearestNeighborFeatures(Phi, nc)
            %Includes feature function information of neighboring cells
            %Can only be executed after standardization/rescaling!
            %nc/nf: coarse/fine elements in x/y direction
            disp('Including nearest neighbor feature function information...')
            nElc = prod(nc);
            nFeatureFunctions = numel(Phi.featureFunctions);
            PhiCell{1} = zeros(nElc, 5*nFeatureFunctions);
            nTrain = length(Phi.dataSamples);
            PhiCell = repmat(PhiCell, nTrain, 1);
            
            for s = 1:nTrain
                %The first columns contain feature function information of the original cell
                PhiCell{s}(:, 1:nFeatureFunctions) = Phi.designMatrices{s};
                
                %Only assign nonzero values to design matrix for neighboring elements if
                %neighbor in respective direction exists
                for i = 1:nElc
                    if(mod(i, nc(1)) ~= 0)
                        %right neighbor of coarse element exists
                        PhiCell{s}(i, (nFeatureFunctions + 1):(2*nFeatureFunctions)) =...
                           Phi.designMatrices{s}(i + 1, :);
                    end
                    
                    if(i <= nc(1)*(nc(2) - 1))
                        %upper neighbor of coarse element exists
                        PhiCell{s}(i, (2*nFeatureFunctions + 1):(3*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + nc(1), :);
                    end
                    
                    if(mod(i - 1, nc(1)) ~= 0)
                        %left neighbor of coarse element exists
                        PhiCell{s}(i, (3*nFeatureFunctions + 1):(4*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - 1, :);
                    end
                    
                    if(i > nc(1))
                        %lower neighbor of coarse element exists
                        PhiCell{s}(i, (4*nFeatureFunctions + 1):(5*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - nc(1), :);
                    end
                end
            end
            Phi.designMatrices = PhiCell;
            disp('done')
        end%includeNearestNeighborFeatures
        
        
        function Phi = includeLocalNearestNeighborFeatures(Phi, nc)
            %Includes feature function information of neighboring cells
            %Can only be executed after standardization/rescaling!
            %nc/nf: coarse/fine elements in x/y direction
            disp('Including nearest neighbor feature function information separately for each cell...')
            nElc = prod(nc);
            nFeatureFunctions = numel(Phi.featureFunctions);
%             PhiCell{1} = zeros(nElc, 5*nFeatureFunctions);
            nTrain = length(Phi.dataSamples);
%             PhiCell = repmat(PhiCell, nTrain, 1);
            
            for s = 1:nTrain
                %Only assign nonzero values to design matrix for neighboring elements if
                %neighbor in respective direction exists
                k = 0;
                for i = 1:nElc
                    PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                        Phi.designMatrices{s}(i, :);
                    Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                        (1:nFeatureFunctions)'; %feature index
                    Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                        i; %coarse element index
                    Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                        0; %center element
                    k = k + 1;
                    if(mod(i, nc(1)) ~= 0)
                        %right neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + 1, :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            1; %right neighbor
                        k = k + 1;
                    end
                    
                    if(i <= nc(1)*(nc(2) - 1))
                        %upper neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + nc(1), :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            2; %upper neighbor
                        k = k + 1;
                    end
                    
                    if(mod(i - 1, nc(1)) ~= 0)
                        %left neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - 1, :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            3; %left neighbor
                        k = k + 1;
                    end
                    
                    if(i > nc(1))
                        %lower neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - nc(1), :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            4; %lower neighbor
                        k = k + 1;
                    end
                end
            end
            Phi.designMatrices = PhiCell;
            disp('done')
        end%includeLocalNearestNeighborFeatures
        
        
        function Phi = includeDiagNeighborFeatures(Phi, nc)
            %includes feature function information of all other cells
            %Can only be executed after standardization/rescaling!
            %nc/nf: coarse/fine elements in x/y direction
            disp('Including nearest and diagonal neighbor feature function information...')
            nElc = prod(nc);
            nFeatureFunctions = numel(Phi.featureFunctions);
            PhiCell{1} = zeros(nElc, 9*nFeatureFunctions);
            nTrain = length(Phi.dataSamples);
            PhiCell = repmat(PhiCell, nTrain, 1);
            
            for s = 1:nTrain
                %The first columns contain feature function information of the original cell
                PhiCell{s}(:, 1:nFeatureFunctions) = Phi.designMatrices{s};
                
                %Only assign nonzero values to design matrix for neighboring elements if
                %neighbor in respective direction exists
                for i = 1:nElc
                    if(mod(i, nc(1)) ~= 0)
                        %right neighbor of coarse element exists
                        PhiCell{s}(i, (nFeatureFunctions + 1):(2*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + 1, :);
                        if(i <= nc(1)*(nc(2) - 1))
                            %upper right neighbor of coarse element exists
                            PhiCell{s}(i, (2*nFeatureFunctions + 1):(3*nFeatureFunctions)) =...
                                Phi.designMatrices{s}(i + nc(1) + 1, :);
                        end
                    end
                    
                    if(i <= nc(1)*(nc(2) - 1))
                        %upper neighbor of coarse element exists
                        PhiCell{s}(i, (3*nFeatureFunctions + 1):(4*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + nc(1), :);
                        if(mod(i - 1, nc(1)) ~= 0)
                            %upper left neighbor exists
                            PhiCell{s}(i, (4*nFeatureFunctions + 1):(5*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + nc(1) - 1, :);
                        end
                    end
                    
                    if(mod(i - 1, nc(1)) ~= 0)
                        %left neighbor of coarse element exists
                        PhiCell{s}(i, (5*nFeatureFunctions + 1):(6*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - 1, :);
                        if(i > nc(1))
                            %lower left neighbor exists
                            PhiCell{s}(i, (6*nFeatureFunctions + 1):(7*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - nc(1) - 1, :);
                        end
                    end
                    
                    if(i > nc(1))
                        %lower neighbor of coarse element exists
                        PhiCell{s}(i, (7*nFeatureFunctions + 1):(8*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - nc(1), :);
                        if(mod(i, nc(1)) ~= 0)
                            %lower right neighbor exists
                            PhiCell{s}(i, (8*nFeatureFunctions + 1):(9*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - nc(1) + 1, :);
                        end
                    end
                end
            end
            Phi.designMatrices = PhiCell;
            disp('done')
        end%includeDiagNeighborFeatures
        
        
        
        function Phi = includeLocalDiagNeighborFeatures(Phi, nc)
            %Includes feature function information of direct and diagonal neighboring cells
            %Can only be executed after standardization/rescaling!
            %nc/nf: coarse/fine elements in x/y direction
            disp('Including nearest + diagonal neighbor feature function information separately for each cell...')
            nElc = prod(nc);
            nFeatureFunctions = numel(Phi.featureFunctions);
%             PhiCell{1} = zeros(nElc, 5*nFeatureFunctions);
            nTrain = length(Phi.dataSamples);
%             PhiCell = repmat(PhiCell, nTrain, 1);
            
            for s = 1:nTrain
                %Only assign nonzero values to design matrix for neighboring elements if
                %neighbor in respective direction exists
                k = 0;
                for i = 1:nElc
                    PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                        Phi.designMatrices{s}(i, :);
                    Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                        (1:nFeatureFunctions)'; %feature index
                    Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                        i; %coarse element index
                    Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                        0; %center element
                    k = k + 1;
                    if(mod(i, nc(1)) ~= 0)
                        %right neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + 1, :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            1; %right neighbor
                        k = k + 1;
                        
                        if(i <= nc(1)*(nc(2) - 1))
                            %upper right neighbor of coarse element exists
                            PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                                Phi.designMatrices{s}(i + nc(1) + 1, :);
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                                (1:nFeatureFunctions)'; %feature index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                                i; %coarse element index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                                2; % upper right neighbor
                            k = k + 1;
                        end
                        
                    end
                    
                    
                    if(i <= nc(1)*(nc(2) - 1))
                        %upper neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i + nc(1), :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            2; %upper neighbor
                        k = k + 1;
                        
                        if(mod(i - 1, nc(1)) ~= 0)
                            %upper left neighbor of coarse element exists
                            PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                                Phi.designMatrices{s}(i + nc(1) - 1, :);
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                                (1:nFeatureFunctions)'; %feature index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                                i; %coarse element index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                                4; % upper left neighbor
                            k = k + 1;
                        end
                        
                    end
                    
                    
                    if(mod(i - 1, nc(1)) ~= 0)
                        %left neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - 1, :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            3; %left neighbor
                        k = k + 1;
                        
                        if(i > nc(1))
                            %lower left neighbor of coarse element exists
                            PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                                Phi.designMatrices{s}(i - nc(1) - 1, :);
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                                (1:nFeatureFunctions)'; %feature index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                                i; %coarse element index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                                6; % lower left neighbor
                            k = k + 1;
                        end
                        
                    end
                    
                    
                    if(i > nc(1))
                        %lower neighbor of coarse element exists
                        PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                            Phi.designMatrices{s}(i - nc(1), :);
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                            (1:nFeatureFunctions)'; %feature index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                            i; %coarse element index
                        Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                            4; %lower neighbor
                        k = k + 1;
                        
                        if(mod(i, nc(1)) ~= 0)
                            %lower right neighbor of coarse element exists
                            PhiCell{s}(i, (k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions)) =...
                                Phi.designMatrices{s}(i - nc(1) + 1, :);
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 1) = ...
                                (1:nFeatureFunctions)'; %feature index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 2) = ...
                                i; %coarse element index
                            Phi.neighborDictionary((k*nFeatureFunctions + 1):((k + 1)*nFeatureFunctions), 3) = ...
                                8; % lower right neighbor
                            k = k + 1;
                        end
                        
                    end
                end
            end
            Phi.designMatrices = PhiCell;
            disp('done')
        end%includeLocalDiagNeighborFeatures
        
        
        function Phi = localTheta_c(Phi, nc)
            %Sets separate coefficients theta_c for each macro-cell in a single microstructure
            %sample
            %Can never be executed before rescaling/standardization of design Matrix!
            disp('Using separate feature coefficients theta_c for each macro-cell in a microstructure...')
            nElc = prod(nc);
            nFeatureFunctions = numel(Phi.featureFunctions);
            PhiCell{1} = zeros(nElc, nElc*nFeatureFunctions);
            nTrain = length(Phi.dataSamples);
            PhiCell = repmat(PhiCell, nTrain, 1);
            
            %Reassemble design matrix
            for s = 1:nTrain
                for i = 1:nElc
                    PhiCell{s}(i, ((i - 1)*nFeatureFunctions + 1):(i*nFeatureFunctions)) = ...
                      Phi.designMatrices{s}(i, :);
                    PhiCell{s} = sparse(PhiCell{s});
                end
            end
            Phi.designMatrices = PhiCell;
            disp('done')
            
        end%localTheta_c
        
        function Phi = computeFeatureFunctionMinMax(Phi)
            %Computes min/max of feature function outputs over training data
            Phi.featureFunctionMin = min(Phi.designMatrices{1});
            Phi.featureFunctionMax = max(Phi.designMatrices{1});
            for i = 1:numel(Phi.designMatrices)
                min_i = min(Phi.designMatrices{i});
                max_i = max(Phi.designMatrices{i});
                Phi.featureFunctionMin(Phi.featureFunctionMin > min_i) = min_i(Phi.featureFunctionMin > min_i);
                Phi.featureFunctionMax(Phi.featureFunctionMax < max_i) = max_i(Phi.featureFunctionMax < max_i);
            end
        end
        
        function Phi = computeFeatureFunctionMean(Phi)
            Phi.featureFunctionMean = 0;
            for i = 1:numel(Phi.designMatrices)
                %                 Phi.featureFunctionMean = Phi.featureFunctionMean + mean(abs(Phi.designMatrices{i}), 1);
                Phi.featureFunctionMean = Phi.featureFunctionMean + mean(Phi.designMatrices{i}, 1);
            end
            Phi.featureFunctionMean = Phi.featureFunctionMean/numel(Phi.designMatrices);
        end
        
        function Phi = computeFeatureFunctionSqMean(Phi)
            featureFunctionSqSum = 0;
            for i = 1:numel(Phi.designMatrices)
                featureFunctionSqSum = featureFunctionSqSum + sum(Phi.designMatrices{i}.^2, 1);
            end
            Phi.featureFunctionSqMean = featureFunctionSqSum/...
                (numel(Phi.designMatrices)*size(Phi.designMatrices{1}, 1));
        end
        
        function Phi = rescaleDesignMatrix(Phi, featFuncMin, featFuncMax)
            %Rescale design matrix s.t. outputs are between 0 and 1
            disp('Rescale design matrix...')
            if(nargin > 1)
                for i = 1:numel(Phi.designMatrices)
                    Phi.designMatrices{i} = (Phi.designMatrices{i} - featFuncMin)./...
                        (featFuncMax - featFuncMin);
                end
            else
                Phi = Phi.computeFeatureFunctionMinMax;
                for i = 1:numel(Phi.designMatrices)
                    Phi.designMatrices{i} = (Phi.designMatrices{i} - Phi.featureFunctionMin)./...
                        (Phi.featureFunctionMax - Phi.featureFunctionMin);
                end
            end
            %Check for finiteness
            for i = 1:numel(Phi.designMatrices)
                if(~all(all(all(isfinite(Phi.designMatrices{i})))))
                    warning('Non-finite design matrix Phi. Setting non-finite component to 0.')
                    Phi.designMatrices{i}(~isfinite(Phi.designMatrices{i})) = 0;
                    dataPoint = i
                    [coarseElement, featureFunction] = ind2sub(size(Phi.designMatrices{i}),...
                        find(~isfinite(Phi.designMatrices{i})))
                elseif(~all(all(all(isreal(Phi.designMatrices{i})))))
                    warning('Complex feature function output:')
                    dataPoint = i
                    [coarseElement, featureFunction] = ind2sub(size(Phi.designMatrices{i}),...
                        find(imag(Phi.designMatrices{i})))
                    disp('Ignoring imaginary part...')
                    Phi.designMatrices{i} = real(Phi.designMatrices{i});
                end
            end
            disp('done')
        end
        
        function Phi = standardizeDesignMatrix(Phi, featFuncMean, featFuncSqMean)
            %Standardize covariates to have 0 mean and unit variance
            disp('Standardize design matrix')
            %Compute std
            if(nargin > 1)
                Phi.featureFunctionStd = sqrt(featFuncSqMean - featFuncMean.^2);
            else
                Phi = Phi.computeFeatureFunctionMean;
                Phi = Phi.computeFeatureFunctionSqMean;
                Phi.featureFunctionStd = sqrt(Phi.featureFunctionSqMean - Phi.featureFunctionMean.^2);
                if(any(~isreal(Phi.featureFunctionStd)))
                    warning('Imaginary standard deviation. Setting it to 0.')
                    Phi.featureFunctionStd = real(Phi.featureFunctionStd);
                end
            end
            
            %centralize
            if(nargin > 1)
                for i = 1:numel(Phi.designMatrices)
                    Phi.designMatrices{i} = Phi.designMatrices{i} - featFuncMean;
                end
            else
                for i = 1:numel(Phi.designMatrices)
                    Phi.designMatrices{i} = Phi.designMatrices{i} - Phi.featureFunctionMean;
                end
            end
            
            %normalize
            for i = 1:numel(Phi.designMatrices)
                Phi.designMatrices{i} = Phi.designMatrices{i}./Phi.featureFunctionStd;
            end
            
            %Check for finiteness
            for i = 1:numel(Phi.designMatrices)
                if(~all(all(all(isfinite(Phi.designMatrices{i})))))
                    warning('Non-finite design matrix Phi. Setting non-finite component to 0.')
                    Phi.designMatrices{i}(~isfinite(Phi.designMatrices{i})) = 0;
                elseif(~all(all(all(isreal(Phi.designMatrices{i})))))
                    warning('Complex feature function output:')
                    dataPoint = i
                    [coarseElement, featureFunction] = ind2sub(size(Phi.designMatrices{i}),...
                        find(imag(Phi.designMatrices{i})))
                    disp('Ignoring imaginary part...')
                    Phi.designMatrices{i} = real(Phi.designMatrices{i});
                end
            end
            disp('done')
        end
        
        
        function Phi = normalizeDesignMatrix(Phi, normalizationFactors)
            %Normalize feature functions s.t. they lead to outputs of same magnitude.
            %This makes the likelihood gradient at theta_c = 0 better behaved.
            if(nargin > 1)
                for i = 1:numel(Phi.designMatrices)
                    Phi.designMatrices{i} = Phi.designMatrices{i}./normalizationFactors;
                end
            else
                for i = 1:numel(Phi.designMatrices)
                    Phi.designMatrices{i} = Phi.designMatrices{i}./Phi.featureFunctionAbsMean;
                end
            end
            for i = 1:numel(Phi.designMatrices)
                if(~all(all(all(isfinite(Phi.designMatrices{i})))))
                    warning('Non-finite design matrix Phi. Setting non-finite component to 0.')
                    Phi.designMatrices{i}(~isfinite(Phi.designMatrices{i})) = 0;
                elseif(~all(all(all(isreal(Phi.designMatrices{i})))))
                    warning('Complex feature function output:')
                    dataPoint = i
                    [coarseElement, featureFunction] = ind2sub(size(Phi.designMatrices{i}),...
                        find(imag(Phi.designMatrices{i})))
                    disp('Ignoring imaginary part...')
                    Phi.designMatrices{i} = real(Phi.designMatrices{i});
                end
            end
        end
        
        function saveNormalization(Phi, type)
            if(isempty(Phi.featureFunctionMean))
                Phi = Phi.computeFeatureFunctionMean;
            end
            if(isempty(Phi.featureFunctionSqMean))
                Phi = Phi.computeFeatureFunctionSqMean;
            end
            if strcmp(type, 'standardization')
                featureFunctionMean = Phi.featureFunctionMean;
                featureFunctionSqMean = Phi.featureFunctionSqMean;
                save('./data/featureFunctionMean', 'featureFunctionMean', '-ascii');
                save('./data/featureFunctionSqMean', 'featureFunctionSqMean', '-ascii');
            elseif strcmp(type, 'rescaling')
                featureFunctionMin = Phi.featureFunctionMin;
                featureFunctionMax = Phi.featureFunctionMax;
                save('./data/featureFunctionMin', 'featureFunctionMin', '-ascii');
                save('./data/featureFunctionMax', 'featureFunctionMax', '-ascii');
            else
                error('Which type of data normalization?')
            end
            
        end
        
        function Phi = computeSumPhiTPhi(Phi)
            Phi.sumPhiTPhi = 0;
            for i = 1:numel(Phi.dataSamples)
                Phi.sumPhiTPhi = Phi.sumPhiTPhi + Phi.designMatrices{i}'*Phi.designMatrices{i};
            end
        end
        
        
        
    end
    
end








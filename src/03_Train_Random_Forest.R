argv <- commandArgs(trailingOnly=T)

# response classes for random forest
classes <- data.frame(id=c(0,1,2,3,4,5,6),
                      class=c("other","cereals","crop_grass","beans","corn","cotton","actual_grass"))

include <- function(x,from="cran",repo=NULL){
  if(from == "cran"){
    if(!do.call(require,as.list(x))) install.packages(x, repos=c("http://cran.revolutionanalytics.com","http://cran.us.r-project.org"));
    if(!do.call(require,as.list(x))) stop("auto installation of package ",x," failed.\n")
  } else if(from == "github"){
    if(!do.call(require,as.list(x))){
      if(!do.call(require,as.list('devtools'))) install.packages('devtools', repos=c("http://cran.revolutionanalytics.com","http://cran.us.r-project.org"));
      require('devtools');
      install_github(paste(repo,x,sep="/"));
    }
  } else{
    stop(paste("could find package:",x))
  }
}

include('raster')
include('rgdal')
include('randomForest')
include('rfUtilities')

#
# Local functions
#

#
# parseLayerDsn()
# parses a full system path into a layer name and partial path (DSN)
# that can be used easily with readOGR() or for various other operations.
#
parseLayerDsn <- function(x=NULL){
  path <- unlist(strsplit(x, split="/"))
    layer <- gsub(path[length(path)],pattern=".shp",replacement="")
      dsn <- paste(path[1:(length(path)-1)],collapse="/")
  return(c(layer,dsn))
}
#
# memFree()
# system independent approach to returning
# amount of free memory in kilobytes
#
memFree <- function(){
  platform <- Sys.info()['sysname']
  if(grepl(tolower(platform),pattern="linux")){
    t <- readLines("/proc/meminfo")
      t <- t[grepl(t,pattern="MemFree")]
        t <- unlist(strsplit(t,split= " "))

    return(as.numeric(t[length(t)-1]))
  }
}
projectObjectSize <- function(nrow=NULL, nVars=NULL, asPercentFreeMem=T){
   dim <- rep(floor(sqrt(nrow*nVars)),2)
  size <- object.size(data.frame(matrix(data=1:prod(dim), nrow=dim[1], ncol=dim[2])))

  if(asPercentFreeMem){
    return(as.numeric(size*0.001)/memFree())
  } else {
    return(size)
  }
}
#
# getImportance()
# Detemine variable importance from a random forest object using methods outlines by (fill-in-with-M.Murphy citation here)
#
getImportance <- function(m,metric="MDA",cutoff=0.35,plot=NULL){
  n <- names(importance(m)[,3])
  if(grepl(tolower(metric),pattern="mda")){ # Mean Decrease Accuracy
    cutoff <- quantile(importance(m)[,3],p=cutoff) # convert our cut-off to a quantile value consistent with the distribution of our metric
      cutoff <- cutoff/max(as.vector(importance(m)[,3]))
    importance <- as.vector(importance(m)[,3])/max(as.vector(importance(m)[,3]))
  } else if(grepl(tolower(metric),pattern="positive-class")){ # Importance for predicting 1
    cutoff <- quantile(importance(m)[,2],p=cutoff) # convert our cut-off to a quantile value consistent with the distribution of our metric
      cutoff <- cutoff/max(as.vector(importance(m)[,2]))
    importance <- as.vector(importance(m)[,2])/max(as.vector(importance(m)[,2]))
  } else if(grepl(tolower(metric),pattern="neg-class")){ # Importance for predicting 0
    cutoff <- quantile(importance(m)[,1],p=cutoff) # convert our cut-off to a quantile value consistent with the distribution of our metric
      cutoff <- cutoff/max(as.vector(importance(m)[,1]))
    importance <- as.vector(importance(m)[,1])/max(as.vector(importance(m)[,1]))
  }
  # plot a distribution of our scaled variable importance values? (useful for estimating cutoffs)
  if(!is.null(plot)){
    dev.new()
    plot(density(importance),main=paste("metric=",metric,"; cut-off=",cutoff,sep=""),cex.main=0.8,cex=1.3,xlab="scaled importance value", ylab="density")
    grid();grid();
  }
  # return the most important variables based on metric/cutoff value?
  if(!is.null(cutoff)){
    return(data.frame(var=n[importance>=cutoff],importance=importance[importance>=cutoff]))
  }
  return(data.frame(var=n,importance=importance))
}


#
# qaCheck_dropVarsWithAbundantNAs()
#
qaCheck_dropVarsWithAbundantNAs <- function(t){
  names <- names(t)
  for(n in names){
    if(sum(is.na(t[,n]))/nrow(t) > 0.8){
      cat(" -- (warning) dropping variable ",n," from consideration, because it would result in a ",(sum(is.na(t[,n]))/nrow(t)*100), "% loss of training data due to NA values\n",sep="")
      t <- t[,names(t)!=n]
    }
  }
  return(t)
}
#
# qaCheck_checkBalancedClasses()
#
qaCheck_checkBalancedClasses<- function(t,correct=F){
  t <- na.omit(t) # we will have to omit some records before training -- what will that do to our class balance?
  min <- table(t$response)
    min <- min(min[min>0])
  ratio <- table(t$response)
    ratio <- (ratio/min) - 1

  if(sum(ratio > 0.65)) {
    cat(" -- (warning) there's a fairly large class imbalance observed in the data (1,2,3,4,5,6): ",paste(ratio,collapse=","), "\n",sep="")
  }
  if(correct){
    cat(" -- corrected by downsampling to less abundant class\n")
  }
  if(nrow(t)==0){
    stop("Training table is completely NA.  This shouldn't happen.")
  }
  return(t)
}
#
# qaCheck_multiColinearity()
#
qaCheck_multiColinearity <- function(t){
  coVars <- suppressWarnings(rfUtilities::multi.collinear(t))
  if(length(coVars)>0){
    cat(" -- (warning) dropped variables due to multicolinearity:",paste(coVars,collapse=","),"\n",sep="")
    t <- t[,!grepl(names(t),pattern=paste(coVars,collapse="|"))]
  }
  return(t)
}
#
#
#
qaCheck_dropVarsWithPoorExplanatoryPower <- function(m=NULL,t=NULL,p=0.35,plot=FALSE){
  cat(" -- (warning) dropping uninformative variables :\n",
    paste(colnames(t)[!grepl(colnames(t),pattern=paste(as.vector(getImportance(m,cutoff=p)[,1]),collapse="|"))],"\n",sep=""))
  t <- cbind(response=t[,'response'],
             t[,grepl(colnames(t),pattern=paste(as.vector(getImportance(m,cutoff=p)[,1]),collapse="|"))])
  return(t)
}
#
# chunk()
#
chunk <- function(x,size=200){
  split(x, ceiling(seq_along(x)/size))
}
#
# qaCheck_findConvergence()
# Use a quick likelihood ratio to find chunks that are significantly (p>=95%) different than the tail of
# OOB error observed in a random forest object.  Report the right-hand side (upper-bound) of the last significant
# chunk back to the user to help establish a cut-off for re-training a forest.  This is an approximation of a moving
# window analysis (or perhaps, a non-moving window analysis... ;-))to find a value appropriate for twice-the-rate-of-convergence
# rule usually applied to picking an appropriate ntrees parameter for randomForest.
#
qaCheck_findConvergence <- function(m=NULL,chunkSize=100){
  err <- abs(diff(diff(m$err.rate[,1])))
    err <- chunk(err,size=chunkSize)

  tailTrainingData <- as.vector(unlist(err[length(err)-3:length(err)]))
    tailTrainingData <- c(mean(tailTrainingData),sd(tailTrainingData))

  means <- as.vector(unlist(lapply(err,FUN=mean)))
    sds <- as.vector(unlist(lapply(err,FUN=sd)))

  sigs <- dnorm(x=tailTrainingData[1],mean=tailTrainingData[1],sd=tailTrainingData[2],log=F)/dnorm(x=means[1:length(err)],mean=tailTrainingData[1],sd=tailTrainingData[2],log=F)
    sigs <- sigs >= 1.96
      sigs <- max(which(sigs==TRUE))

  return(sigs*chunkSize)
}
#
# MAIN
#
if(!file.exists(paste(parseLayerDsn(argv[1])[1],"_prob_occ.tif",sep=""))){
  cat(" -- training random forests\n")
  # read-in our training data
  training_pts <- readOGR(".",paste(parseLayerDsn(argv[1])[1],"_farmed_binary_pts",sep=""),verbose=F)
  # read-in our explanatory data
  expl_vars <- list.files(pattern=paste("^",parseLayerDsn(argv[1])[1],".*.tif$",sep=""))
    expl_vars <- expl_vars[!grepl(expl_vars,pattern="farmed")]
      expl_vars <- raster::stack(expl_vars)
  names <- unlist(lapply(strsplit(names(expl_vars),split="_"),FUN=function(x){ x[length(x)] }))
    names(expl_vars) <- names
  # Ensure a consistent CRS
  training_pts <- spTransform(training_pts,CRS(projection(expl_vars)))
  # do we have a cached table to work with?
  if(file.exists("training_table_extract_cache.csv")){
    cat(" -- using cached training table\n")
    training_table <- bigmemory::read.big.matrix("training_table_extract_cache.csv",header=T)
  } else {
    # extract across our training points
    training_pts_ <- try(training_pts[!is.na(extract(subset(expl_vars,subset='X14'),training_pts)),]) # the geometry of our aquifer data can be limiting here...
      if(class(training_pts_) == "try-error") { rm(training_pts_) } else { training_pts <- training_pts_; rm(training_pts_) }
    training_table <- extract(expl_vars,training_pts,df=T)
      training_table <- cbind(data.frame(response=training_pts$response),training_table[,!grepl(names(training_table),pattern="ID$")])
    # QA Check our training data
    training_table$slope[is.na(training_table$slope)] <- 0
    training_table <- qaCheck_dropVarsWithAbundantNAs(training_table)
    training_table <- qaCheck_checkBalancedClasses(training_table)
    training_table <- qaCheck_multiColinearity(training_table)
    # if this is a large table, let's cache it to disk
    if(nrow(training_table)>100000){
      write.csv(training_table,"training_table_extract_cache.csv",row.names=F)
    }
  }

  # Use a 20% hold-out for validation -- we can easily spare this when working with big datasets
  rows <- sample(1:nrow(training_table),size=round(0.2*nrow(training_table)))
  holdout <- training_table[rows,]
  training_table <- training_table[!(1:nrow(training_table) %in% rows),]

  # Establish a multiple for downsampling and train an initial forest
  multiple <- 25000/nrow(training_table) # determine a multiple for downsampling out dataset to realize 100,000 observations
    if(multiple>1) {
      multiple <- 1;
      cat(" -- warning: sample space is sparse (fewer than 100,000 records). Will not bootstrap the training data.\n")
    }

  focal <- training_table[sample(1:nrow(training_table),size=round(multiple*nrow(training_table))),]

  cat("## Preliminary Burn-in/Evaluative Forest ##\n")
  rf.initial <- m <- randomForest::randomForest(as.factor(response)~.,data=focal,importance=T,ntree=1000,do.trace=T)
  # rf.initial <- m <- ranger::ranger(as.factor(response)~.,
  #                                   num.tree=1000,
  #                                   probability=T,
  #                                   importance="impurity",
  #                                   data=as.data.frame(focal),
  #                                   num.threads=8,
  #                                   classification=T,
  #                                   write.forest=T)
  # Post-hoc QA check variable importance
  training_table <- qaCheck_dropVarsWithPoorExplanatoryPower(m,t=training_table)

  # bootstrap our training data, if appropriate
  if(round(1/multiple)>1){
    nForests <- round((1/multiple)/3)
    cat(paste(" -- bootstrap training ",nForests, " forests from ",nrow(training_table)," records\n",sep=""))
    forests <- vector('list',nForests)
    for(i in 1:nForests){
      focal <- training_table[sample(1:nrow(training_table),size=round(multiple*nrow(training_table))),]
          m <- randomForest(as.factor(response)~.,data=focal,importance=T,ntree=1000,do.trace=T)
      ntree <- qaCheck_findConvergence(m,chunkSize=10)*4
      forests[[i]] <- randomForest(as.factor(response)~.,data=focal,importance=T,ntree=ntree,do.trace=T)
      cat(paste(" -- finished forest [",i,"/",nForests,"]\n"))
    }
    # merge our forests into a single random forest
    cat(" -- merging forests\n")
    rf.final <- do.call(randomForest::combine,forests)
  } else { # for smaller datasets, don't bootstrap -- build a model based on what we have
    cat(" -- re-training a final forest, optimizing based on 2X convergence of OOB error in the final model\n")
    m <- randomForest(as.factor(response)~.,data=focal,importance=T,ntree=1000,do.trace=T)
    ntree <- qaCheck_findConvergence(m,chunkSize=10)*2
    if(ntree<200){
      dev.new()
        plot(abs(diff(diff(m$err.rate[,1]))),type="l", xlab="N trees", ylab="2nd Deriv. OOB Error")
          abline(v=ntree,col="red",lwd=1.1)
      cat(" -- warning: ML estimator for convergence is predicting a small number of trees for convergence:",ntree,"-- adjusting to 500 trees\n")
      ntree <- 500;
    }
    cat(" -- training final random forest:\n")
    rf.final <- randomForest(as.factor(response)~.,data=training_table,importance=T,ntree=ntree,do.trace=T)
  }
  cat(" -- ")

  cat(" -- predicting across explanatory raster series for focal county:\n")
    r_projected <- subset(expl_vars,subset=which(grepl(names(expl_vars),pattern=paste(names(training_table)[names(training_table)!="response"],collapse="|")))) # subset our original raster stack to only include our "keeper" variables
      r_predicted <- predict(r_projected,model=rf.final,progress='text',type='prob',na.rm=T,inf.rm=T,index=which(as.numeric(rf.final$classes) %in% c(6,5,4,2,1))) # let's always try and predict corn, cotton, wheat, and grass for a focal county
        names(r_predicted) <- as.vector(classes$class[classes$id %in% as.numeric(rf.final$classes[which(as.numeric(rf.final$classes) %in% c(6,5,4,2,1))])])
  cat(" -- saving results to disk\n")
  session <- new.env()
  assign("rf.initial",value=rf.initial,env=session)
  assign("rf.final",value=rf.final,env=session)
    assign("training_table",value=training_table,env=session)
      assign("expl_vars",value=expl_vars,env=session)
    assign("training_pts",value=training_pts,env=session)
  assign("r_predicted",value=r_predicted,env=session)

  writeRaster(r_predicted,paste(parseLayerDsn(argv[1])[1],"_prob_occ.tif",sep=""),overwrite=T)
  save(list=ls(session),envir=session,file=paste(parseLayerDsn(argv[1])[1],"_model.rdata",sep=""),compress=T)

  cat(" -- done\n")
}

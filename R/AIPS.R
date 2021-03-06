require(e1071) ## for naive bayes classifier
require(Biobase)

.smaller <- function(x,y){
    stopifnot(length(x) == length(y))
    to.ret <- (x < y)
    to.ret[x == 0 & y == 0] <- NA
    to.ret
}

## Functions necessary to run AIPS
.comp.sel.pairs <- function(dataset,sel.pairs,func=.smaller){
  to.ret <- matrix(NA,nrow=length(sel.pairs),ncol(dataset$exprs))
  for (spi in 1:length(sel.pairs)){
    ss.cur <- strsplit(sel.pairs[spi],"<")[[1]]
    gene1 = which(dataset$GeneName == ss.cur[1])
    gene2 = which(dataset$GeneName == ss.cur[2])
    #stopifnot(length(gene1) == 1 & length(gene2) == 1)
    if (length(gene1) == 1 & length(gene2) == 1){
      to.ret[spi,] <- func(dataset$exprs[gene1,],dataset$exprs[gene2,])
    }
    else{
      ## message(paste("You are missing the pair or have more than one",sel.pairs[spi],"in",dataset$name))
    }
  }
  to.ret <- apply(to.ret,2,as.numeric)
  rownames(to.ret) <- sel.pairs
  to.ret
}

.one.vs.all.tsp <- function(D,GeneName,one.vs.all.tsp){
  ## Need to add some QC
  ## First compute
  train.pairs <- .comp.sel.pairs(list(exprs=D,GeneName=GeneName),one.vs.all.tsp$all.pairs)

  classes <- matrix("",ncol=length(one.vs.all.tsp$k),nrow=ncol(D))
  prob <- matrix(0,ncol=length(one.vs.all.tsp$k),nrow=ncol(D))
  colnames(classes) <- colnames(prob) <- as.character(one.vs.all.tsp$k)
  rownames(classes) <- rownames(prob) <-colnames(D)
  nb.d <- data.frame(t(train.pairs))
  all.probs <- list()
  for (ki in one.vs.all.tsp$k){
    ## message(sprintf("Current k = %d",ki))
    prob.train <- predict(one.vs.all.tsp$one.vs.all.tsp[[ki]],nb.d,type="raw")
    cur.cl <- apply(prob.train,1,function(prob.cur){colnames(prob.train)[which.max(prob.cur)]})
    cur.prob <- apply(prob.train,1,function(prob.cur){max(prob.cur)})
    prob[,as.character(ki)] <- cur.prob
    classes[,as.character(ki)] <- cur.cl
    all.probs[[as.character(ki)]] <- prob.train
  }
  ## invisible(list(cl = classes,prob = prob,all.probs = all.probs,rules.matrix=train.pairs))
  invisible(list(cl = classes,prob = prob,all.probs = all.probs))
}

.get.all.pairs.genes <- function(all.pairs){
  genes <- c()
  for (cp in strsplit(all.pairs,"<")){
    genes <- c(genes,cp)
  }
  unique(genes)
}
## Remove the duplicated Entrez by keeping the most higly expressed
## This is closer to the single sample selection
## D is a raw gene expression matrix rows == genes and columns patients
.removeDuplicatedEntrezPerPatients <- function(D,EntrezID,probes){
  ## Maybe we have nothing to do already
  if (all(!duplicated(EntrezID))){
    return(list(dataset=D,EntrezID=EntrezID))
  }
  else{
    uniqEntrez <- sort(unique(EntrezID))
    newD <- matrix(0,nrow=length(uniqEntrez),ncol=ncol(D))
    if (!missing(probes)){
      sel.probes <- matrix("",nrow=length(uniqEntrez),ncol=ncol(D))
    }
    for (i in 1:ncol(D)){
      curD <- D[,i]
      curEntrez <- EntrezID
      oi <- order(curD,decreasing=T) ## order by raw expression
      curD <- curD[oi]
      curEntrez <- curEntrez[oi]
      cur.sel <- !duplicated(curEntrez) ## remove duplicated
      curD <- curD[cur.sel]
      curEntrez <- curEntrez[cur.sel]
      reorder <- match(uniqEntrez,curEntrez)
      newD[,i] <- curD[reorder]
      if (!missing(probes)){
        sel.probes[,i] <- probes[oi][cur.sel][reorder]
      }
    }
    colnames(newD) <- colnames(D)
    if (!missing(probes)){
      colnames(sel.probes) <- colnames(D)
      return(list(dataset=newD,EntrezID=uniqEntrez,probes=sel.probes))
    }
    else{
      return(list(dataset=newD,EntrezID=uniqEntrez))
    }
  }
}

.apply.nbc <- function(D,EntrezID,sel.nbc){
  ## Verify the number of rows of D and EntrezIDs have the same length 
  if (nrow(D) != length(EntrezID)){
    stop(sprintf("You need the same number of rows and EntrezID. Right now nrow(D) = %d and length(EntrezID) = %d",nrow(D),length(EntrezID)))
  }
  ## AIPS needs to be applied on expression values > 0. Require 95% of the values to be > 0
  if (!all(apply(D,2,function(x){(sum(x < 0,na.rm=T)/length(x)) < 0.05}))){
    stop("AIPS needs to be applied on expressionn values > 0. Did you gene-centered your matrix D? You should not.")
  }
  
  ## Verify if D is a numeric matrix
  if (!all(apply(D,2,is.numeric))){
    stop("Verify D is a numeric matrix. apply(D,2,as.numeric) could do the job or verify the first column doesn't contain probe ids") 
  }
  
  D <- apply(D,2,as.numeric)
  EntrezID <- as.character(EntrezID)
  sel.ids.nb <- .get.all.pairs.genes(sel.nbc$all.pairs)
  sel.gn <- EntrezID %in% sel.ids.nb
  D <- D[sel.gn,,drop=FALSE]
  Entrez <- EntrezID[sel.gn]
  col.D.test <- .removeDuplicatedEntrezPerPatients(D,Entrez)
  pred.test <- .one.vs.all.tsp(D=col.D.test$dataset,
                              GeneName=col.D.test$EntrezID,
                              sel.nbc)

  ## Add more information to the output variable
  ## pred.test$data.used <- col.D.test$dataset
  ## pred.test$EntrezID.used <- col.D.test$EntrezID
  
  invisible(pred.test)
}

apply.AIPS <- function(D,EntrezID){
    data(aips.models)
    message(sprintf("Applying %d AIPS models",length(aips.models)))
    aips.assignments <- lapply(1:length(aips.models),function(current.model.i){
                                           if (current.model.i %% 100 == 1){
                                               message(sprintf("Assigning AIPS model %d/%d",current.model.i,length(aips.models)))
                                           }
                                           current.model <- aips.models[[current.model.i]]
                                           .apply.nbc(D,EntrezID,current.model$model$model)
                                       })
    
    cl.all <- t(sapply(aips.assignments,function(x){x$cl}))
    posterior.probs.all <- t(sapply(aips.assignments,function(x){x$prob}))

    if (ncol(D) == 1){
        cl.all <- matrix(cl.all,nrow=length(cl.all),ncol=1)
        posterior.probs.all <- matrix(posterior.probs.all,
                                      nrow=length(posterior.probs.all),
                                      ncol=1)
    }

    gs.info <- cbind(Name=as.character(lapply(aips.models,function(x){x$gs.bresat$NAME})),
                     Source=as.character(lapply(aips.models,function(x){x$gs.bresat$DATA_SOURCE})),
                     Description=as.character(lapply(aips.models,function(x){x$gs.bresat$DESCRIPTION})))

    message(sprintf("Size gs.info %d",nrow(gs.info)))
    message(sprintf("Size cl.all %d",nrow(cl.all)))
    message(sprintf("Size posterior.probs.all %d",nrow(posterior.probs.all)))
    
    rownames(cl.all) <- gs.info[,"Name"]
    rownames(posterior.probs.all) <- gs.info[,"Name"]
    colnames(cl.all) <- colnames(D)
    colnames(posterior.probs.all) <- colnames(D)
    invisible(list(cl=cl.all,
                   posterior=posterior.probs.all,
                   gs.info=gs.info,
                   raw.aips=aips.assignments))
}

## Multicore version for better speed
mclapply.AIPS <- function(D,EntrezID,n.cores=max((detectCores()-2),1)){
    require(parallel)
    data(aips.models)
    message(sprintf("Applying %d AIPS model",length(aips.models)))
    aips.assignments <- mclapply(1:length(aips.models),function(current.model.i){
        if (current.model.i %% 100 == 1){
            message(sprintf("Assigning AIPS model %d/%d",current.model.i,length(aips.models)))
        }
        current.model <- aips.models[[current.model.i]]
        .apply.nbc(D,EntrezID,current.model$model$model)
    },mc.cores=n.cores)
    
    cl.all <- t(sapply(aips.assignments,function(x){x$cl}))
    posterior.probs.all <- t(sapply(aips.assignments,function(x){x$prob}))

    if (ncol(D) == 1){
        cl.all <- matrix(cl.all,nrow=length(cl.all),ncol=1)
        posterior.probs.all <- matrix(posterior.probs.all,
                                      nrow=length(posterior.probs.all),
                                      ncol=1)
    }

    gs.info <- cbind(Name=as.character(lapply(aips.models,function(x){x$gs.bresat$NAME})),
                     Source=as.character(lapply(aips.models,function(x){x$gs.bresat$DATA_SOURCE})),
                     Description=as.character(lapply(aips.models,function(x){x$gs.bresat$DESCRIPTION})))

    message(sprintf("Size gs.info %d",nrow(gs.info)))
    message(sprintf("Size cl.all %d",nrow(cl.all)))
    message(sprintf("Size posterior.probs.all %d",nrow(posterior.probs.all)))
    
    rownames(cl.all) <- gs.info[,"Name"]
    rownames(posterior.probs.all) <- gs.info[,"Name"]
    colnames(cl.all) <- colnames(D)
    colnames(posterior.probs.all) <- colnames(D)
    invisible(list(cl=cl.all,
                   posterior=posterior.probs.all,
                   gs.info=gs.info,
                   raw.aips=aips.assignments))
}

.random.ranks <- function(bs, n=1000, r.seed=1234)
{
  set.seed(r.seed)
  
  ## single gene ranks for every up genes
  datrank.up <- c()
  datrank.dn <- c()
  sel.up <- bs$up.dn > 0
  sel.dn <- bs$up.dn < 0

  if (any(sel.up)){
    datrank.up <- t(apply(bs$dat[sel.up, , drop=FALSE], 1, function(x) {rank(x, "average", na.last="keep")}))
  }
  if (any(sel.dn)){
    ## single gene ranks for every down genes need to do N - rank
    datrank.dn <- ncol(bs$dat) - t(apply(bs$dat[sel.dn, , drop=FALSE], 1, function(x) {rank(x, "average", na.last="keep")})) + 1
  }
  
  ## merge up and down
  datrank <- rbind(datrank.up, datrank.dn)
  col.sum.datarank <- sort(colSums(datrank,na.rm=T)) 
  
  ## nvals.cols <- nrow(datrank) - c(colSums(is.na(datrank)), 0)
  ## nvals.rows <- ncol(datrank) - rowSums(is.na(datrank))

  ## random.cols <- t(sapply(1:nrow(datrank), function(i) {runif(n, 0, nvals.rows[i] + 1)}))
  temp.sort <- c(col.sum.datarank,0)
  rand.dist <- sapply(1:n, function(i) {
    temp.sort[length(temp.sort)] <- sum(sample(1:ncol(datrank),nrow(datrank),replace=T))
    tail(rank(temp.sort, "average", na.last=TRUE), 1)
  })
  
  ret <- hist(rand.dist, breaks=0:(ncol(datrank)+1), plot=FALSE)$counts
  list(cnts=ret,
       rnks=rank(colSums(datrank,na.rm=T), "average", na.last=TRUE),
       datrank=datrank,
       datrank.up=datrank.up,
       datrank.down=datrank.dn)
}

## Select the most variable genes
.select.most.variable <- function (exprs, genename, sel.func = IQR)
{
    stopifnot(nrow(exprs) == length(genename))
    iqr.e <- apply(exprs, 1, sel.func)
    order.iqr <- order(iqr.e, decreasing = T)
    exprs <- exprs[order.iqr, , drop = F]
    genename <- genename[order.iqr]
    keep.most.variable <- !duplicated(genename)
    exprs <- exprs[keep.most.variable, , drop = F]
    genename <- genename[keep.most.variable]
    invisible(list(exprs = exprs, genename = genename))
}

ROIq <- function(D,genename,gene.set,n=1000,q=0.95){
  sel.genes <- genename %in% c(gene.set$up,gene.set$dn)

  iqr.sel.genes <- .select.most.variable(D[sel.genes,],genename[sel.genes])
  up.dn <- rep(0,nrow(iqr.sel.genes$exprs))
  up.dn[iqr.sel.genes$genename %in% gene.set$up] <- 1
  up.dn[iqr.sel.genes$genename %in% gene.set$dn] <- -1
  
  rr.obj <- list(dat=iqr.sel.genes$exprs,
                 up.dn=up.dn)
  
  random.rank.counts <- .random.ranks(rr.obj,n=n)

  tot <- sum(random.rank.counts$cnts)
  
  random.ranks.cdf <- cumsum(random.rank.counts$cnts) / tot
  
  left <- max(c(0, which(random.ranks.cdf < (1 - q) / 2)))
  right <- min(which(random.ranks.cdf > 1 - ((1 - q) / 2))) - 1
  calls <- rep("random",ncol(D))
  calls[random.rank.counts$rnks < left] <- "low"
  calls[random.rank.counts$rnks > right] <- "high"
  
  list(cl=calls)
}



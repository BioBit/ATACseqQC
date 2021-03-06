#' scan ATAC-seq footprints infer factor occupancy genome wide
#' @description Aggregate ATAC-seq footprint for a bunch of motifs generated
#'              over binding sites within the genome.
#' @param bamExp A vector of characters indicates the file names of experiment bams. 
#' The bam file must be the one with shifted reads.
#' @param bamCtl A vector of characters indicates the file names of control bams. 
#' The bam file must be the one with shifted reads.
#' @param indexExp,indexCtl The names of the index file of the 'BAM' file being processed;
#'        This is given without the '.bai' extension.
#' @param bindingSitesList A object of \link[GenomicRanges:GRangesList-class]{GRangesList} indicates
#' candidate binding sites (eg. the output of fimo).
#' @param seqlev A vector of characters indicates the sequence levels.
#' @param proximal,distal numeric(1) or integer(1).
#'        basepair for open region from binding sites (proximal) and extented region for background (distal) 
#'        of the binding region for aggregate ATAC-seq footprint.
#' @param gap numeric(1) or integer(1). basepair for gaps among binding sites, 
#'            proximal, and distal. default is 5L.
#' @param maximalBindingWidth numeric(1) or integer(1). Maximal binding sites width for
#'                            all the motifs. If setted, all motif binding sites will be 
#'                            re-sized to this value. 
#' @param cutoffLogFC,cutoffPValue numeric(1). Cutoff value for differential bindings.
#' @param correlatedFactorCutoff numeric(1). Cutoff value for correlated factors. 
#' If the overlapping binding site within 100bp is more than cutoff, the TFs will be treated as correlated factors.
#' @importFrom stats p.adjust pnorm
#' @importFrom ChIPpeakAnno estLibSize reCenterPeaks
#' @importFrom GenomicAlignments readGAlignments summarizeOverlaps
#' @importFrom Biostrings matchPWM maxScore
#' @importFrom Rsamtools ScanBamParam
#' @import edgeR
#' @import GenomeInfoDb
#' @import GenomicRanges
#' @import IRanges
#' @import S4Vectors
#' @return a list.
#' It includes:
#'  - bindingSites            GRanges of binding site with hits of reads
#'  - data                    a list with test result for each binding site
#'  - results                 a data.frame with open score and enrichment score of motifs
#' @export
#' @author Jianhong Ou
#' @examples
#'
#'bamfile <- system.file("extdata", "GL1.bam",
#'                        package="ATACseqQC")
#'bsl <- system.file("extdata", "jolma2013.motifs.bindingList.95.rds",
#'                   package="ATACseqQC")
#'bindingSitesList <- readRDS(bsl)
#'footprintsScanner(bamfile, seqlev="chr1", bindingSitesList=bindingSitesList)
#'
footprintsScanner <- function(bamExp, bamCtl, indexExp=bamExp, indexCtl=bamCtl, 
                              bindingSitesList, seqlev=paste0("chr", c(1:25, "X", "Y")),  
                              proximal=40L, distal=proximal, gap=10L, 
                              maximalBindingWidth=NA, 
                              cutoffLogFC=log2(1.5),
                              cutoffPValue=0.05,
                              correlatedFactorCutoff=3/4){
  ## compare signal vs. inputs, negative binomial test
  ## reads must be shifted. 5' end counts
  ## 2 steps: 
  ## Step1: open region counts comparison
  ## Step2: binding region counts comparison
  ## if there is two group, exp vs input,
  ## open region = 50bp from binding site edge
  ## binding region = binding motif width
  ## if there is one one group, proximal (50bp) vs. distal (50bp) or auto
  ## distal is set to control
  ## output motif open score, motif enrichment score, pvalue, p-adjust, 
  ## motifName, footprints curve data for downstream plot.
  ## open score = log2 fold change of open region
  ## enrichment score = log2 fold change of binding site 
  stopifnot(is.numeric(proximal))
  stopifnot(is.numeric(distal))
  stopifnot(is.numeric(gap))
  proximal <- as.integer(proximal)
  distal <- as.integer(distal)
  gap <- as.integer(gap)
  stopifnot(proximal>10 && distal>10)
  if(missing(bamExp)){
    stop("bamExp is required.")
  }
  if(missing(bindingSitesList)){
    stop("bindingSitesList is required.")
  }else{
    mts <- lapply(bindingSitesList, function(bindingSites){
      if(!is(bindingSites, "GRanges")){
        stop("bindingSitesList must be a object of GRangesList")
      }
      if(length(bindingSites)<=1){
        stop("The length of elements in bindingSitesList must be greater than 1.")
      }
      bindingSites[seqnames(bindingSites) %in% seqlev]
    })
  }
  mts <- mts[lengths(mts)>100]
  if(length(mts)<1){
    stop("no enough bindingsites in given seqlev.")
  }
  mts.unlist <- unlist(GRangesList(mts), use.names = FALSE)
  mts.unlist$motif <- rep(names(mts), lengths(mts))
  names(mts.unlist) <- 
    paste0("pos", formatC(seq.int(length(mts.unlist)), 
                          width = nchar(as.character(length(mts.unlist))), 
                          flag = "0"))
  seqlev <- intersect(seqlevels(mts.unlist), seqlev)
  seqlevels(mts.unlist) <- seqlevels(mts.unlist)[seqlevels(mts.unlist) %in% seqlev]
  seqinfo(mts.unlist) <- Seqinfo(seqlev, seqlengths = seqlengths(mts.unlist))
  ## set all binding sites width identical
  if(!is.na(maximalBindingWidth[1])){
    maximalBindingWidth <- maximalBindingWidth[1]
    stopifnot(is.numeric(maximalBindingWidth))
    mts.unlist <- reCenterPeaks(mts.unlist, 
                                width = round(maximalBindingWidth))
  }
  mts.unlist.with.proximal <- mts.unlist.with.distal <- mts.unlist
  mts.unlist.with.proximal.gap <- mts.unlist.with.distal.gap <- mts.unlist
  start(mts.unlist.with.proximal) <- start(mts.unlist) - proximal - gap
  end(mts.unlist.with.proximal) <- end(mts.unlist) + proximal + gap
  start(mts.unlist.with.distal) <- start(mts.unlist) - proximal - 2*gap - distal
  end(mts.unlist.with.distal) <- end(mts.unlist) + proximal + distal + 2*gap
  start(mts.unlist.with.proximal.gap) <- start(mts.unlist) - gap
  end(mts.unlist.with.proximal.gap) <- end(mts.unlist) + gap
  start(mts.unlist.with.distal.gap) <- start(mts.unlist) - proximal - 2*gap
  end(mts.unlist.with.distal.gap) <- end(mts.unlist) + proximal + 2*gap
  ## get total reads counts
  bams <- data.frame(bamfiles = bamExp, index = indexExp, group="Exp", stringsAsFactors = FALSE)
  if(!missing(bamCtl)){
    bams <- rbind(bams, 
                  data.frame(bamfiles = bamCtl, index = indexCtl, group="Ctl", stringsAsFactors = FALSE))
  }
  bams$libSize <- estLibSize(bamfiles = bams$bamfiles, index = bams$index)
  bams$sample <- sub(".bam", "", make.names(basename(bams$bamfiles)))
  ## count reads by 5'ends
  count5ends <- function(bam, index, chunk=100000, binding, pro, dis, pro.gap, dis.gap){
    ## check rowRanges order
    stopifnot(all(distance(binding, pro)==0))
    stopifnot(all(distance(pro, dis)==0))
    bamfile <- BamFile(bam, index=index, yieldSize=chunk)
    open(bamfile)
    counts <- data.frame(bs=rep(0, length(binding)),
                         pro.gap=rep(0, length(pro.gap)),
                         pro=rep(0, length(pro)),
                         dis.gap=rep(0, length(dis.gap)),
                         dis=rep(0, length(dis)))
    while (length(chunk0 <- readGAlignments(bamfile))) {
      ## keep 5' end only
      chunk0 <- as(chunk0, "GRanges")
      chunk0 <- promoters(chunk0, upstream = 0, downstream = 1)
      ## counts of binding sites
      so.bs <- countOverlaps(binding, chunk0, ignore.strand=TRUE)
      ## counts of binding sites + gap
      so.pro.gap <- countOverlaps(pro.gap, chunk0, ignore.strand=TRUE)
      ## counts of binding sites + proximal
      so.pro <- countOverlaps(pro, chunk0, ignore.strand=TRUE)
      ## counts of binding sites + gap + proximal + gap
      so.dis.gap <- countOverlaps(dis.gap, chunk0, ignore.strand=TRUE)
      ## counts of binding sites + proximal + distal
      so.dis <- countOverlaps(dis, chunk0, ignore.strand=TRUE)
      counts <- counts + data.frame(bs=so.bs,
                                    pro.gap=so.pro.gap,
                                    pro=so.pro,
                                    dis.gap=so.dis.gap,
                                    dis=so.dis)
    }
    close(bamfile)
    counts$dis <- counts$dis - counts$dis.gap
    counts$pro <- counts$pro - counts$pro.gap
    counts$pro.gap <- NULL
    counts$dis.gap <- NULL
    stopifnot(all(counts$dis>=0))
    stopifnot(all(counts$pro>=0))
    rownames(counts) <- names(binding)
    counts
  }
  counts <- mapply(function(a, b) count5ends(bam=a, index=b, binding = mts.unlist, 
                                             pro=mts.unlist.with.proximal, 
                                             dis=mts.unlist.with.distal,
                                             pro.gap=mts.unlist.with.proximal.gap,
                                             dis.gap=mts.unlist.with.distal.gap), 
                   bams$bamfiles, bams$index, SIMPLIFY = FALSE)
  names(counts) <- bams$sample
  ## filter 0 counts
  keep <- lapply(counts, function(.ele) rowSums(.ele)>0)
  keep <- do.call(cbind, keep)
  keep <- rowSums(keep) > 0
  counts <- lapply(counts, function(.ele) .ele[keep, , drop=FALSE])
  mts.unlist <- mts.unlist[keep]
  ## normalize counts by width of count region
  ## normalize by width
  wid <- width(mts.unlist)
  names(wid) <- names(mts.unlist)
  norm.counts <- lapply(counts, function(.ele){
    round(.ele*max(c(wid, proximal, distal))/data.frame(bs=wid/2, pro=proximal, dis=distal))
  })
  ## split the reads counts by samples
  groupNames <- colnames(norm.counts[[1]])
  norm.cnt <- lapply(groupNames, function(.ele) {
    x <- do.call(cbind, lapply(norm.counts, `[`, i=.ele))
    colnames(x) <- names(norm.counts)
    x
  })
  names(norm.cnt) <- groupNames
  
  ## calculate the log2 fold change of open score and binding score
  ## open data == log2(proximal in exp) - log2(proximal in ctl)
  ## or            log2(proximal) - log2(distal)
  ## binding data == log2(binding in exp) - log2(binding in ctl)
  ## or               log2(proximal) - log2(binding) ## get positive value
  ## and get p value via edgeR
  if(!missing(bamCtl)){
    data <- list(openData = norm.cnt[["pro"]],
                 bindData = norm.cnt[["bs"]]) ## for binding site, the avoidence is enrichment, so need reverse.
    grp <- bams$group
    libSize <- bams$libSize
  }else{
    data <- list(openData = cbind(norm.cnt[["pro"]], norm.cnt[["dis"]]),
                 bindData = cbind(norm.cnt[["pro"]], norm.cnt[["bs"]]))
    grp <- rep(c("Exp", "Ctl"), each=ncol(norm.cnt[["pro"]]))
    libSize <- rep(bams$libSize, 2)
  }
  res <- lapply(data, DB, libSize=libSize, group=grp)
  ## reveser the enrichment for binding sites
  if(!missing(bamCtl)){
    res[["bindData"]]$logFC <- -1 * res[["bindData"]]$logFC
  }
  ## split the reads counts by factor
  res <- lapply(res, split, f=mts.unlist$motif)
  correlationScore <- function(mts.unlist){
    #if the binding site overlaps within 100bp more than half of the binding sites
    ol <- findOverlaps(mts.unlist, maxgap = 100, drop.self = TRUE, drop.redundant = TRUE)
    qh <- mts.unlist[queryHits(ol)]$motif
    sh <- mts.unlist[subjectHits(ol)]$motif
    keep <- qh!=sh
    qh <- qh[keep]
    sh <- sh[keep]
    tab <- table(data.frame(query=qh, subject=sh))
    tab2 <- table(mts.unlist$motif)
    per <- apply(tab, 2, function(.ele) .ele/tab2[rownames(tab)])
    per <- per[match(colnames(per), rownames(per)), ]
    rownames(per) <- colnames(per)
    per[is.na(per)] <- 0
    per
  }
  cs <- correlationScore(mts.unlist)
  correlatedFactors <- function(cs, cutoff=3/4){
    #hc <- hclust(as.dist(cs), method = "average")
    w <- which(cs>cutoff)
    i <- w - nrow(cs)*floor(w/nrow(cs))
    j <- ceiling(w/nrow(cs))
    g <- split(c(rownames(cs)[i], colnames(cs)[j]), c(colnames(cs)[j], rownames(cs)[i]))
    g <- g[rownames(cs)]
    names(g) <- rownames(cs)
    g <- mapply(c, g, names(g))
    g <- unname(g)
    g <- lapply(g, sort)
    unique(g)
  }
  cf <- correlatedFactors(cs, cutoff = correlatedFactorCutoff)
  ## cutoff the values by logFC > log2(1.5) && FDR < 0.05
  countTable <- function(x, fc=cutoffLogFC, pval=cutoffPValue, alternative=c("greater", "less", "both")){
    alternative <- match.arg(alternative)
    x <- do.call(rbind, lapply(x, function(.ele){
      .ele <- switch(alternative, 
                     "greater"= table(.ele$logFC > fc & .ele$PValue < pval)[c("FALSE", "TRUE")],
                     "less" = table(.ele$logFC < -1*fc & .ele$PValue < pval)[c("FALSE", "TRUE")],
                     "both" = table(abs(.ele$logFC) > fc & .ele$PValue < pval)[c("FALSE", "TRUE")])
      .ele[is.na(.ele)] <- 0
      names(.ele) <- c("FALSE", "TRUE")
      .ele
    }))
    ## get open or binding percentage and then Z-score
    percent <- 100*x[, "TRUE"]/rowSums(x)
    percent[is.infinite(percent)] <- 0
    ## need to remove the correlated factors?
    ## correlated factors, 
    per.clean <- sapply(cf, function(.ele){
      mean(percent[.ele])
    })
    Z <- (percent - mean(per.clean))/sd(per.clean)
    Z[is.na(Z)] <- -Inf
    ## get p-value
    pval <- pnorm(-Z) ## one side, over
    cbind(score=percent, pval)
  }
  enrich.counts <- lapply(res, countTable, alternative="greater")
  enrich.counts <- do.call(cbind, enrich.counts)
  reduce.counts <- lapply(res, countTable, alternative="less")
  reduce.counts <- do.call(cbind, reduce.counts)
  alter.counts <- lapply(res, countTable, alternative="both")
  alter.counts <- do.call(cbind, alter.counts)
  
  colnames(enrich.counts) <- paste(rep(c("proximalSiteOpen", "bindingSiteEnrichment"), 
                                       each=ncol(enrich.counts)/2),
                                   colnames(enrich.counts), sep=".")
  colnames(reduce.counts) <- paste(rep(c("proximalSiteClose", "bindingSiteReduction"), 
                                       each=ncol(reduce.counts)/2),
                                   colnames(reduce.counts), sep=".")
  colnames(alter.counts) <- paste(rep(c("proximalSiteAlter", "bindingSiteAlter"), 
                                       each=ncol(alter.counts)/2),
                                   colnames(alter.counts), sep=".")
  
  stopifnot(identical(rownames(enrich.counts), rownames(reduce.counts)))
  stopifnot(identical(rownames(enrich.counts), rownames(alter.counts)))
  res.counts <- cbind(enrich.counts, reduce.counts, alter.counts)
  return(list(bindingSites=mts.unlist,
              data=res,
              results=res.counts))
}


#' helper function for preparing the binding list
#' @rdname footprintsScanner
#' @param pfms A list of Position frequency Matrix represented as a numeric matrix
#'        with row names A, C, G and T.
#' @param genome An object of \link[BSgenome:BSgenome-class]{BSgenome}.
#' @param expSiteNum numeric(1). Expect number of predicted binding sites.
#'        if predicted binding sites is more than this number, top expSiteNum binding
#'        sites will be used.
#' @importFrom Biostrings matchPWM maxScore
#' @export
#' @examples
#' library(MotifDb)
#' motifs <- query(MotifDb, c("Hsapiens"))
#' motifs <- as.list(motifs)
#' library(BSgenome.Hsapiens.UCSC.hg19)
#' #bindingSitesList <- prepareBindingSitesList(motifs, genome=Hsapiens)
prepareBindingSitesList <- function(pfms, genome, 
                                    seqlev=paste0("chr", c(1:22, "X", "Y")),
                                    expSiteNum=5000){
  mts <- lapply(pfms, function(pfm){
    if(!all(round(colSums(pfm), digits=4)==1)){
      stop("pfms must be list of Position frequency Matrix")
    }
    pwm <- motifStack::pfm2pwm(pfm)
    min.score <- 95
    suppressWarnings({
      mt <- matchPWM(pwm, genome, min.score = paste0(min.score, "%"),
                     with.score=TRUE, exclude=names(genome)[!names(genome) %in% seqlev])
    })
    while(length(mt)<expSiteNum && min.score>80){
      min.score <- min.score - 5
      suppressWarnings({
        mt <- matchPWM(pwm, genome, min.score = paste0(min.score, "%"),
                       with.score=TRUE, exclude=names(genome)[!names(genome) %in% seqlev])
      })
    }
    if(length(mt)>expSiteNum){## subsample
      mt$oid <- seq_along(mt)
      mt <- mt[order(mt$score, decreasing = TRUE)]
      mt <- mt[mt$score>=mt$score[expSiteNum]]
      mt <- mt[order(mt$oid)]
      mt$oid <- NULL
    }
    mt$string <- NULL
    mt
  })
}

#' helper function for differential binding
#' @param counts count table
#' @param libSize library size
#' @param group group design
#' @param default.bcv a reasonable dispersion value 
#' @return topTable
#' @importFrom stats model.matrix
DB <- function(counts, libSize, group, default.bcv=0.3){
  stopifnot(length(libSize)==ncol(counts))
  if(any(duplicated(colnames(counts)))){
    colnames(counts) <- make.names(colnames(counts), unique = TRUE)
  }
  d <- DGEList(counts = counts, lib.size = libSize, 
               group = factor(group, levels = c("Ctl", "Exp")))
  d <- calcNormFactors(d, method = "RLE") ## normalization method
  mm <- model.matrix(~group)
  suppressWarnings(d <- estimateDisp(d, mm))
  if(any(is.na(d$common.dispersion))){
    et <- exactTest(d, dispersion = default.bcv^2)
    res <- et$table
    res$FDR <- p.adjust(res$PValue, method = "BH")
  }else{
    f <- glmFit(d, mm)
    lrt <- glmLRT(f, coef=2)
    res <- topTags(lrt, n = nrow(lrt), sort.by="none")
    res <- as.data.frame(res)
  }
  stopifnot(identical(rownames(counts), rownames(res)))
  stopifnot(all(c("logFC", "FDR") %in% colnames(res)))
  return(res)
}

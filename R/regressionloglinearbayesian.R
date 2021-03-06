#
# Copyright (C) 2013-2018 University of Amsterdam
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

RegressionLogLinearBayesian <- function(jaspResults, dataset = NULL, options, ...) {
  ready <- length(options$factors) > 1
  if(ready){
    dataset <- .basRegLogLinReadData(dataset, options)
    .basRegLogLinCheckErrors(dataset, options)
  }
  # Container
  .basRegLogLinContainer(jaspResults, dataset, options)
  container <- jaspResults[["Container"]]
  # Output tables (each calls its own results function)
  .basRegLogLinMainTable(      container, dataset, options, ready)
  .basRegLogLinSummaryTable(   container, dataset, options, ready)
  .basRegLogLinSubSummaryTable(container, dataset, options, ready)
  
  return()
}

# Preprocessing functions 
.basRegLogLinReadData <- function(dataset, options) {
  if (!is.null(dataset))
    return(dataset)
  else {
    counts <- factors <- NULL
    if(options$counts != "")
      counts <- options$counts
    if(length(options$modelTerms) > 0)
      factors <- options$modelTerms
    return(.readDataSetToEnd(columns.as.factor = factors, 
                             columns.as.numeric = counts))
  }
}  

.basRegLogLinCheckErrors <- function(dataset, options) {
  # Error Check 1
  args <- list(
    dataset = dataset,
    type    = c("missingValues", "modelInteractions"),
    modelInteractions.modelTerms = options$modelTerms,
    missingValues.target = options$factors,
    exitAnalysisIfErrors = TRUE
  )
  
  if (options$counts != "") {
    args$type <- c(args$type, "infinity", "negativeValues")
    args$missingValues.target <- c(options$counts, options$factors)
  }
  
  do.call(.hasErrors, args)
} 

# Compute results 
.basRegLogLinComputeBFObject <- function(container, dataset, options) {
  if(!is.null(container[["bfObject"]])) 
    return(container[["bfObject"]]$object)
  
  bfObject <- list("bcctObj"        = NULL, 
                   "variables"      = c(".", "."),
                   "nModelsVisited" = NULL,
                   "nBurnIn"        = NULL,
                   "bf10s"          = rep(".", length = 2), 
                   "postModelProbs" = rep(".", length = 2), 
                   "modelNames"     = NULL)
  numberOfModels   <- length(options$modelTerms)
  variablesInModel <- bcctObj <- NULL

  if (options$counts == "")
    dataset <- plyr::count(dataset)
  
  # Extract models needed to be compared
  if (options$counts == "")
    dependentVariable <- "freq"
  else
    dependentVariable <- unlist(options$counts)
  
  dependentBase64 <- .v(dependentVariable)
  if (length(options$modelTerms) > 0) {
    variablesInModel <- variablesInModelBase64 <- NULL
    
    for (i in seq_along(options$modelTerms)) {
      components <- options$modelTerms[[i]]$components
      if (length(components) == 1) {
        term <- components[[1]]
        termBase64 <- .v(components[[1]])
      } else {
        componentsUnlisted <- unlist(components)
        term       <- paste0(componentsUnlisted, collapse = ":")
        termBase64 <- paste0(.v(componentsUnlisted), collapse = ":")
      }
      # Add to tally
      variablesInModel       <- c(variablesInModel, term)
      variablesInModelBase64 <- c(variablesInModelBase64, termBase64)
      
      # Remove empty stuff
      variablesInModel <- variablesInModel[variablesInModel != ""]
    }
  }
  
  # Prune the variables
  if (length(variablesInModel) == 0) {
    variablesInModel <- c("...", "... ")
    modelDefinition  <- NULL #this model has no parameters
  } else if (length(variablesInModel) == 1 && options$counts == "") {
    variablesInModel <- c(variablesInModel, "... ")
    modelDefinition  <- NULL #this model has only one parameter
  } else if (length(variablesInModel) > 1 || options$counts != "") {
    modelDefinition <- paste(dependentBase64, "~", 
                             paste(variablesInModelBase64, collapse = "+"))
  } else {
    # Nothing worked out:
    modelDefinition <- NULL #this model has no parameters
    stop(gettext("variables cannot be read"))
  }
  
  # Save in object
  bfObject$variables <- variablesInModel
  # START analysis Bayesian Log Linear regression
  if (!is.null(modelDefinition)) {
    modelFormula <- as.formula(modelDefinition)
    
    if (options$counts == "")
      names(dataset)[names(dataset) == "freq"] <- dependentBase64
    # Calculate here
    #gives an object computed using Bayesian Analysis of Complete Contingency Tables
    .setSeedJASP(options)
    bcctObj <- try(conting::bcct(formula = modelFormula, data = dataset, 
                                 prior = "SBH", n.sample = 2000, 
                                 a = options$priorShape, b = options$priorScale), 
                   silent = TRUE)
    bfObject$nBurnIn <- 2000 * 0.2
    
    # Always do auto and then manual adds additional samples
    if (options$sampleMode == "manual"){
      .setSeedJASP(options)
      bcctObj <- try(conting::bcctu(object = bcctObj, 
                                    n.sample = options$fixedSamplesNumber), 
                     silent = TRUE)
      bfObject$nBurnIn <- (2000 + options$fixedSamplesNumber) * 0.2
    }
    # bcct object checking
    if(inherits(bcctObj, "bcct"))
      bfObject$bcctObj <- bcctObj
    else if(isTryError(bcctObj))
      stop(gettextf("R Package error: %s", .extractErrorMessage(bcctObj)))
  }
  
  # Post processing
  if (inherits(bfObject$bcctObj, "bcct")) {
    # Good case
    # TODO: Here check bcctSummary$totmodsvisit if this is one, 
    # then nothing going on, resample
    #
    bcctSummary <- try(conting::mod_probs(bfObject$bcctObj, scale = 0, 
                                          best = options$maxModels), silent = TRUE)

    if (inherits(bcctSummary, "modprobs")) {
      # Good case
      bfObject$nModelsVisited <- bcctSummary$totmodsvisit
      modelnames <- bcctSummary$table$model_formula
      bfObject$modelNames <- substring(as.character(modelnames), first = 2)
      
      if (bfObject$nModelsVisited == 1)
        bfObject$postModelProbs <- bfObject$bf10s <- 1
      else if (bfObject$nModelsVisited > 1) {
        # Note the following BFs are based on a uniform prior on the models
        if (!is.null(bcctSummary$table$prob.Freq)) {
          postModelProbs <- bcctSummary$table$prob.Freq
          bfObject$postModelProbs <- postModelProbs
          bfObject$bf10s <-  postModelProbs/ max(postModelProbs)
        } else {
          # NAs: nModelsVisited, bf10s, postModelProbs
          stop(gettext("R Package error: Cannot retrieve table probabilities"))
        }
      }
    }
  } 
  container[["bfObject"]] <- createJaspState(bfObject)
  container[["bfObject"]]$dependOn(c("fixedSamplesNumber", "sampleMode", "seed", "setSeed"))
  return(bfObject)
}

.basRegLogLinMainResults <- function(container, dataset, options) {
  # Compute/get the model
  bfObject <- .basRegLogLinComputeBFObject(container, dataset, options)

  posteriorTableRows <- list()
  results <- list()

  nModelsReport <- try(min(bfObject$nModelsVisited, options$maxModels))
  if (!is.null(bfObject$modelNames))
    reportNames <- .unvf(bfObject$modelNames)
  else if (!is.null(bfObject$variables)) 
    reportNames <- bfObject$variables
  else 
    reportNames <- c("...", "... ")
  
  if (!is.null(bfObject$bf10s))
    reportBfs <- bfObject$bf10s
  else 
    reportBfs <- rep(NA, length = nModelsReport) 
  if (is.numeric(reportBfs)) {
    if (options$bayesFactorType == "BF01")
      reportBfs <- 1/reportBfs
    else if (options$bayesFactorType == "LogBF10")
      reportBfs <- log(reportBfs)
  }
  if (!is.null(bfObject$postModelProbs))
    reportPostModelProbs <- bfObject$postModelProbs
  else
    reportPostModelProbs <- rep(NA, length = nModelsReport)
  
  for (i in 1:nModelsReport){
    posteriorTableRows[[i]] <- list()
    posteriorTableRows[[i]]$"number"  <- as.integer(i)
    posteriorTableRows[[i]]$"model"   <- reportNames[i]
    posteriorTableRows[[i]]$"pMdata"  <- reportPostModelProbs[i]
    posteriorTableRows[[i]]$"bf"      <- reportBfs[i]
  }
  
  message <- gettextf("Total number of models visited = %i", bfObject$nModelsVisited)
  container[["MainTable"]]$addFootnote(message)
  container[["MainTable"]]$addRows(posteriorTableRows)
}

.basRegLogLinSummaryResults <- function(container, dataset, options) {
  # Compute/get the model
  bfObject <- .basRegLogLinComputeBFObject(container, dataset, options)

  results <- list()
  
  lookup.table <- .regressionLogLinearBayesianBuildLookup(dataset, options$factors)
  lookup.table[["(Intercept)"]] <- "(Intercept)"
  
  if(inherits(bfObject$bcctObj, "bcct")) {
    probLevel <- options$regressionCoefficientsCredibleIntervalsInterval
    logBlm.summary   <- summary(bfObject$bcctObj, 
                                n.burnin = bfObject$nBurnIn, 
                                cutoff = options$posteriorProbabilityCutOff, 
                                prob.level = probLevel)
    logBlm.estimates <- logBlm.summary$int_stats
    
    len.Blogreg <- length(results) + 1		
    term.names  <- logBlm.estimates$term			
    
    if (length(bfObject$variables) > 0) {

      variablesInModel <- bfObject$variables
      terms <- as.character(logBlm.estimates$term)
      coef  <- base::strsplit (terms, split = ":", fixed = TRUE)				

      for (var in seq_along(coef)) {
        
        terms <- coef[[var]]
        actualName <- list()

        for (j in seq_along(terms))
          actualName[[j]] <- paste(lookup.table[[ terms[j] ]], collapse = " = ")
        varName <- paste0(actualName, collapse = "*")
        
        results[[ len.Blogreg ]]             <- list()
        results[[ len.Blogreg ]]$"Name"      <- varName
        results[[ len.Blogreg ]]$"post_prob" <- as.numeric(logBlm.estimates$prob[var])
        results[[ len.Blogreg ]]$"post_mean" <- as.numeric(logBlm.estimates$post_mean[var])
        results[[ len.Blogreg ]]$"post_var"  <- as.numeric(logBlm.estimates$post_var[var])
        
        if (options$regressionCoefficientsCredibleIntervals == TRUE){			
          results[[ len.Blogreg ]]$"lower_lim" <- as.numeric(logBlm.estimates$lower[var])
          results[[ len.Blogreg ]]$"upper_lim" <- as.numeric(logBlm.estimates$upper[var])
        }
        
        len.Blogreg <- len.Blogreg + 1
      }		
    }			

  } else {
    
    len.Blogreg <- length(results) + 1
    
    if (length(bfObject$variables) > 0) {
      
      variablesInModel <- bfObject$variables

      len.Blogreg <- len.Blogreg + 1
      
      for (var in 1:length(variablesInModel)) {
        
        if (base::grepl(":", variablesInModel[var])) {
          
          # if interaction term					
          vars <- unlist(strsplit(variablesInModel[var], split = ":"))
          name <- paste0(vars, collapse = "\u2009\u273b\u2009")
          
        } else 
          name <- as.character(variablesInModel[ var])
        
        results[[ len.Blogreg ]]$"Name" <- name
        len.Blogreg <- len.Blogreg + 1
      }
    }
  }
  container[["SummaryTable"]]$addRows(results)
}

.basRegLogLinSubSummaryResults <- function(container, dataset, options) {
  if(!is.null(container[["SubSummaryResults"]]) || !options$regressionCoefficientsSubmodel) 
    return()
  # Compute/get the model
  bfObject <- .basRegLogLinComputeBFObject(container, dataset, options)
  if(!(options$regressionCoefficientsSubmodelNo %in% 1:bfObject$nModelsVisited))
    stop(gettext("Submodel specified is not within possible submodels"))
  
  results <- list()
  lookup.table <- .regressionLogLinearBayesianBuildLookup(dataset, options$factors)
  lookup.table[["(Intercept)"]] <- "(Intercept)"
  
  if (!is.null(bfObject$bcctObj)) {
    probLevel <- options$regressionCoefficientsSubmodelCredibleIntervalsInterval
    order     <- options$regressionCoefficientsSubmodelNo
    logBlm.subestimates = try(conting::sub_model(bfObject$bcctObj, 
                                                 n.burnin   = bfObject$nBurnIn, 
                                                 order      = order, 
                                                 prob.level = probLevel), 
                              silent = TRUE)
    
    if (inherits(logBlm.subestimates, "submod")){
      
      len.Blogreg <- length(results) + 1		
      term.names  <- logBlm.subestimates$term	
      
      extractedModelFormula <- logBlm.subestimates$formula
      
      extractedModelFormula <- as.character(extractedModelFormula)
      extractedModelFormula <- substring(extractedModelFormula, first = 2) # trim leading ~
      extractedModelFormula <- .unvf(extractedModelFormula)	
      container[["SubSummaryTable"]]$addFootnote(extractedModelFormula, symbol = gettext("<em>Model formula:</em>"))
      container[["SubSummaryTable"]]$addFootnote(paste(round(logBlm.subestimates$post_prob, 3)), symbol = gettext("<em>Posterior model probability =</em>"))

      if (length(bfObject$variables) > 0) {
        
        variablesInModel <- bfObject$variables
        terms <- as.character(logBlm.subestimates$term)
        coef  <- base::strsplit (terms, split = ":", fixed = TRUE)				
        
        for (var in seq_along(coef)) {
          
          terms      <- coef[[var]]
          actualName <- list()
          
          for (j in seq_along(terms))
            actualName[[j]] <- paste(lookup.table[[ terms[j] ]], collapse = " = ")
          varName <- paste0(actualName, collapse = "*")
          
          results[[ len.Blogreg ]] <- list()
          results[[ len.Blogreg ]]$"Name"      <- varName
          results[[ len.Blogreg ]]$"post_mean" <- as.numeric(logBlm.subestimates$post_mean[var])
          results[[ len.Blogreg ]]$"post_var"  <- as.numeric(logBlm.subestimates$post_var[var])
          
          if (options$regressionCoefficientsSubmodelCredibleIntervals){			
            results[[ len.Blogreg ]]$"lower_lim" <- as.numeric(logBlm.subestimates$lower[var])
            results[[ len.Blogreg ]]$"upper_lim" <- as.numeric(logBlm.subestimates$upper[var])
          }
          len.Blogreg <- len.Blogreg + 1
        }		
      }			
      
    } else {
      
      len.Blogreg <- length(results) + 1
      if (length(bfObject$variables) > 0) {
        
        variablesInModel <- bfObject$variables
        
        len.Blogreg <- len.Blogreg + 1
        
        for (var in 1:length(variablesInModel)) {
          
          if (base::grepl(":", variablesInModel[var])) {
            
            # if interaction term					
            vars <- unlist(strsplit(variablesInModel[var], split = ":"))
            name <- paste0(vars, collapse = "\u2009\u273b\u2009")
            
          } else 
            name <- as.character(variablesInModel[ var])
          
          results[[ len.Blogreg ]]$"Name" <- name
          len.Blogreg <- len.Blogreg + 1
        }
      }
    }
    
  } else {		
    
    len.Blogreg <- length(results) + 1
    
    if (length(bfObject$variables) > 0) 
      variablesInModel <- bfObject$variables
    
    results[[ len.Blogreg ]]$"Model" <- 1
  }
  container[["SubSummaryTable"]]$addRows(results)
}

# Container
.basRegLogLinContainer <- function(jaspResults, dataset, options) {
  if(is.null(jaspResults[["Container"]])) {
    jaspResults[["Container"]] <- createJaspContainer()
    jaspResults[["Container"]]$dependOn(c("counts", "modelTerms", "priorShape", 
                                          "priorScale", "sampleMode", "fixedSamplesNumber", "seed", "setSeed"))
  }
}

# Tables
.basRegLogLinMainTable <- function(container, dataset, options, ready) {
  if (!is.null(container[["MainTable"]])) 
    return()
  
  # Create table
  mainTable <- createJaspTable(title = gettext("Model Comparison"))
  mainTable$dependOn(c("bayesFactorType", "maxModels", "posteriorProbabilityCutOff"))
  .basRegLogLinCitation(mainTable)
  mainTable$showSpecifiedColumnsOnly <- TRUE
  mainTable$position <- 1
  if (options$bayesFactorType == "BF10") 
    bfTitle <- gettext("BF<sub>10</sub>")
  else if (options$bayesFactorType == "BF01") 
    bfTitle <- gettext("BF<sub>01</sub>")
  else 
    bfTitle <- gettext("Log(BF<sub>10</sub>)")
  
  # Add columns to table
  mainTable$addColumnInfo(name = "number",  title = " ",                  type = "integer")
  mainTable$addColumnInfo(name = "model",   title = gettext("Models"),    type = "string")
  mainTable$addColumnInfo(name = "pMdata",  title = gettext("P(M|data)"), type = "number", format = "dp:3")
  mainTable$addColumnInfo(name = "bf",      title = bfTitle,              type = "number")

  container[["MainTable"]] <- mainTable
  if (!ready) 
    return()
  res <- try(.basRegLogLinMainResults(container, dataset, options))
  .basRegLogLinSetError(res, mainTable)
}

.basRegLogLinSummaryTable <- function(container, dataset, options, ready){
  if (!is.null(container[["SummaryTable"]]) || 
      !options$regressionCoefficientsEstimates) 
    return()
  
  # Create table
  summaryTable <- createJaspTable(title = gettext("Posterior Summary Statistics"))
  summaryTable$dependOn(c("regressionCoefficientsEstimates",
                          "regressionCoefficientsCredibleIntervals",
                          "regressionCoefficientsCredibleIntervalsInterval"))
  .basRegLogLinCitation(summaryTable)
  summaryTable$showSpecifiedColumnsOnly <- TRUE
  summaryTable$position <- 2
  
  # Add columns to table
  summaryTable$addColumnInfo(name = "Name",      title = " ",                     type = "string")
  summaryTable$addColumnInfo(name = "post_prob", title = gettext("P(incl|data)"), type = "number", format = "dp:3")
  summaryTable$addColumnInfo(name = "post_mean", title = gettext("Mean"),         type = "number", format = "dp:3")
  summaryTable$addColumnInfo(name = "post_var",  title = gettext("Variance"),     type = "number", format = "dp:3")
  if(options$regressionCoefficientsCredibleIntervals){
    ci.label <- gettextf("%s%% Credible intervals", 100*options$regressionCoefficientsCredibleIntervalsInterval)
    summaryTable$addColumnInfo(name = "lower_lim", title = gettext("Lower"), type = "number", overtitle = ci.label)
    summaryTable$addColumnInfo(name = "upper_lim", title = gettext("Upper"), type = "number", overtitle = ci.label)
  }
  
  container[["SummaryTable"]] <- summaryTable
  
  if (!ready) 
    return()
  
  res <- try(.basRegLogLinSummaryResults(container, dataset, options))
  
  .basRegLogLinSetError(res, summaryTable)
}

.basRegLogLinSubSummaryTable <- function(container, dataset, options, ready){
  if (!is.null(container[["SubSummaryTable"]]) || 
      !options$regressionCoefficientsSubmodel) 
    return()
  
  # Create table
  title <- gettextf("Posterior Summary Statistics For Submodel %s", options$regressionCoefficientsSubmodelNo)

  subSummaryTable <- createJaspTable(title = title)
  subSummaryTable$dependOn(c("regressionCoefficientsSubmodel",
                             "regressionCoefficientsSubmodelCredibleIntervals",
                             "regressionCoefficientsSubmodelCredibleIntervalsInterval",
                             "regressionCoefficientsSubmodelNo"))
  .basRegLogLinCitation(subSummaryTable)
  subSummaryTable$showSpecifiedColumnsOnly <- TRUE
  subSummaryTable$position <- 3
  
  # Add columns to table
  subSummaryTable$addColumnInfo(name = "Name",      title = " ",                 type = "string")
  subSummaryTable$addColumnInfo(name = "post_mean", title = gettext("Mean"),     type = "number", format = "dp:3")
  subSummaryTable$addColumnInfo(name = "post_var",  title = gettext("Variance"), type = "number", format = "dp:3")

  if(options$regressionCoefficientsSubmodelCredibleIntervals){
    ciVal    <- options$regressionCoefficientsSubmodelCredibleIntervalsInterval
    ci.label <- gettextf("%.0f%% Credible intervals", 100*ciVal)

    subSummaryTable$addColumnInfo(name = "lower_lim", title = gettext("Lower"), type = "number", overtitle = ci.label)
    subSummaryTable$addColumnInfo(name = "upper_lim", title = gettext("Upper"), type = "number", overtitle = ci.label)
  }
  
  container[["SubSummaryTable"]] <- subSummaryTable
  if (!ready) 
    return()
  res <- try(.basRegLogLinSubSummaryResults(container, dataset, options))
  .basRegLogLinSetError(res, subSummaryTable)
}

# Other 
.basRegLogLinCitation <- function(table) {
  citation <- ("Overstall, A., & King, R. (2014). conting: an R package for 
                Bayesian analysis of complete and incomplete contingency tables. 
                Journal of Statistical Software, 58(7), 1-27.")
  table$addCitation(citation)
}

.basRegLogLinSetError <- function(res, table) {
  if(isTryError(res))
    table$setError(.extractErrorMessage(res))
}

.regressionLogLinearBayesianBuildLookup <- function(dataset, factors) {
  table <- list()
  
  for (factorName in factors) {
    levels <- base::levels(dataset[[ .v(factorName) ]])
    
    for (i in seq_along(levels)) {
      levelName <- levels[i]
      base64Name <- paste(.v(factorName), i, sep="")
      actualName <- c(factorName, levelName)
      table[[base64Name]] <- actualName
    }
  }
  return(table)
}


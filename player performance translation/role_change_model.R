# Dedicated forecasts of changes in minutes, usage and assists. This file uses
# the shared preprocessing and existing ridge/imputation helpers; it does not
# construct windows or write datasets.
.role_sources <- Filter(Negate(is.null),lapply(sys.frames(),function(f) f$ofile))
.role_args <- grep('^--file=',commandArgs(FALSE),value=TRUE)
.role_dir <- if(length(.role_sources)) dirname(tail(.role_sources,1L)[[1L]]) else
  if(length(.role_args)) dirname(sub('^--file=','',.role_args[1L])) else 'player performance translation'
if(!exists('role_change_class',mode='function')) source(file.path(.role_dir,'player_translation_data.R'),encoding='UTF-8')
if(!exists('fit_translation_ridge',mode='function')) source(file.path(.role_dir,'player_translation_model.R'),encoding='UTF-8')

role_change_config <- function() {
  config <- translation_config()
  config$window <- 15L; config$windows <- 15L
  config$validation_start <- as.Date('2021-07-01')
  config$test_start <- as.Date('2024-07-01')
  config$first_role_fold_year <- 2017L
  config$lambda_grid <- c(.01,.1,1,10)
  config$stayer_weight <- .1
  config$direction_threshold <- c(minutes=3,usg=3,ast=3)
  config$simplicity_tolerance <- .01
  config
}

role_fit_weights <- function(data,trade_weight,config) {
  ifelse(data$verified_trade,trade_weight,ifelse(data$transfer,1,config$stayer_weight))
}

fit_role_ols <- function(data,features,y,weights) {
  design <- translation_matrix(data,features)
  x <- cbind('(Intercept)'=1,design$x)
  coefficients <- stats::lm.wfit(x,y,weights)$coefficients
  coefficients[is.na(coefficients)] <- 0
  list(kind='ols',features=features,medians=design$medians,coefficients=coefficients)
}

fit_role_mixture <- function(data,features,y,lambda,weights,threshold) {
  design <- translation_matrix(data,features)
  classes <- role_change_class(y,threshold)
  levels <- levels(classes)
  counts <- table(classes)
  classifier <- if(all(counts>=30L)) glmnet::glmnet(design$x,classes,
    family='multinomial',alpha=0,lambda=sort(unique(lambda),decreasing=TRUE),
    weights=weights,standardize=TRUE,thresh=1e-8) else NULL
  priors <- vapply(levels,function(level) sum(weights[classes==level])/sum(weights),numeric(1))
  magnitudes <- lapply(levels,function(level) {
    use <- which(classes==level)
    if(length(use)<30L) return(list(constant=if(length(use)) weighted.mean(y[use],weights[use]) else 0))
    fit_translation_ridge(data[use,],features,y[use],lambda,weights[use])
  })
  names(magnitudes) <- levels
  list(kind='mixture',classifier=classifier,priors=priors,magnitudes=magnitudes,
       features=features,medians=design$medians,lambda=lambda,threshold=threshold)
}

predict_role_component <- function(model,data,lambda=model$lambda,mode=model$mode) {
  if(model$kind=='ols') {
    x <- translation_matrix(data,model$features,model$medians)$x
    return(matrix(drop(cbind(1,x)%*%model$coefficients),ncol=1L))
  }
  if(model$kind=='ridge') return(predict_translation_ridge(model,data,lambda))
  levels <- c('decrease','stable','increase'); n <- nrow(data)
  if(is.null(model$classifier)) {
    probabilities <- array(rep(rep(model$priors,each=n),length(lambda)),c(n,3L,length(lambda)))
  } else {
    x <- translation_matrix(data,model$features,model$medians)$x
    raw <- stats::predict(model$classifier,newx=x,s=lambda,type='response')
    probabilities <- raw[,match(levels,dimnames(raw)[[2L]]),,drop=FALSE]
  }
  means <- lapply(levels,function(level) {
    fitted <- model$magnitudes[[level]]
    if(!is.null(fitted$constant)) matrix(fitted$constant,n,length(lambda)) else
      predict_translation_ridge(fitted,data,lambda)
  })
  means[[1L]] <- pmin(means[[1L]],-model$threshold)
  means[[2L]] <- pmin(pmax(means[[2L]],-model$threshold+1e-8),model$threshold-1e-8)
  means[[3L]] <- pmax(means[[3L]],model$threshold)
  out <- matrix(NA_real_,n,length(lambda))
  for(j in seq_along(lambda)) {
    probability <- matrix(probabilities[,,j],nrow=n,ncol=3L)
    conditional <- cbind(means[[1L]][,j],means[[2L]][,j],means[[3L]][,j])
    out[,j] <- if(mode=='hard') conditional[cbind(seq_len(n),max.col(probability,ties.method='first'))] else
      rowSums(probability*conditional)
  }
  out
}

role_bounded_delta <- function(delta,data,target) {
  translation_clip(delta+data[[paste0('past_',target)]],target)-data[[paste0('past_',target)]]
}

predict_role_change <- function(model,newdata,method='selected') {
  if(!requireNamespace('glmnet',quietly=TRUE)) stop('Install glmnet to predict roles.')
  if('cutoff'%in%names(newdata)&&any(newdata$cutoff<=model$latest_training_label))
    stop('The role model was trained after the requested cutoff.')
  fits <- if(method=='selected') model$models else model$candidates[[method]]
  if(is.null(fits)) stop('This candidate was not saved; rerun the evaluation to compare candidates.')
  targets <- c('minutes','usg','ast')
  delta <- projected <- matrix(NA_real_,nrow(newdata),3L,dimnames=list(NULL,targets))
  direction <- matrix('',nrow(newdata),3L,dimnames=list(NULL,targets))
  for(target in targets) {
    value <- predict_role_component(fits[[target]],newdata)[,1L]
    delta[,target] <- role_bounded_delta(value,newdata,target)
    projected[,target] <- newdata[[paste0('past_',target)]]+delta[,target]
    direction[,target] <- as.character(role_change_class(delta[,target],model$config$direction_threshold[[target]]))
  }
  list(delta=delta,projected=projected,direction=direction)
}

fit_role_family <- function(family,data,target,lambda,trade_weight,config) {
  names <- translation_feature_names()
  features <- if(family%in%c('direct_ols','player_ridge')) names$role_simple else names$role_opportunity
  weights <- role_fit_weights(data,trade_weight,config)
  y <- data[[paste0('change_',target)]]
  fitted <- if(family=='direct_ols') fit_role_ols(data,features,y,weights) else
    if(grepl('mixture',family)) fit_role_mixture(data,features,y,lambda,weights,config$direction_threshold[[target]]) else {
      result <- fit_translation_ridge(data,features,y,lambda,weights)
      result$kind <- 'ridge'; result
    }
  fitted$family <- family; fitted$trade_weight <- trade_weight
  if(grepl('mixture',family)) fitted$mode <- if(family=='mixture_hard') 'hard' else 'soft'
  fitted
}

fit_role_change <- function(data,config=role_change_config(),boundary=config$test_start,
                            validation_start=config$validation_start,keep_candidates=TRUE) {
  if(!requireNamespace('glmnet',quietly=TRUE)) stop('Install glmnet first.')
  train <- which(data$target_end<validation_start)
  validation <- which(data$cutoff>=validation_start & data$target_end<boundary & data$verified_trade)
  development <- which(data$target_end<boundary)
  if(length(train)<100L||length(validation)<20L) stop('Not enough past training rows or actual validation trades.')
  stopifnot(max(data$target_end[train])<min(data$cutoff[validation]))
  targets <- c('minutes','usg','ast')
  families <- c('direct_ols','player_ridge','opportunity_ridge','mixture_soft','mixture_hard')
  chosen <- list(); candidates <- setNames(lapply(families,function(x) list()),families)
  tuning <- list(); selections <- list()
  for(target in targets) {
    actual <- data[[paste0('change_',target)]][validation]
    best <- setNames(vector('list',length(families)),families)
    for(base_family in c('direct_ols','player_ridge','opportunity_ridge','mixture_soft')) {
      weights <- if(base_family=='direct_ols') 1 else config$trade_weights
      for(weight in weights) {
        lambdas <- if(base_family=='direct_ols') NA_real_ else config$lambda_grid
        path <- fit_role_family(base_family,data[train,],target,lambdas,weight,config)
        modes <- if(base_family=='mixture_soft') c('soft','hard') else 'soft'
        for(mode in modes) {
          family <- if(base_family=='mixture_soft'&&mode=='hard') 'mixture_hard' else base_family
          prediction <- role_bounded_delta(predict_role_component(path,data[validation,],lambdas,mode),data[validation,],target)
          for(j in seq_along(lambdas)) {
            error <- prediction[,j]-actual
            large <- abs(actual)>=5
            trial <- list(family=family,target=target,lambda=lambdas[j],trade_weight=weight,
              mae=mean(abs(error)),rmse=sqrt(mean(error^2)),bias=mean(error),
              large_mae=if(any(large)) mean(abs(error[large])) else NA_real_,
              direction_accuracy=mean(role_change_class(prediction[,j],config$direction_threshold[[target]])==
                role_change_class(actual,config$direction_threshold[[target]])))
            if(is.null(best[[family]])||trial$mae<best[[family]]$mae-1e-10) best[[family]] <- trial
          }
        }
      }
    }
    table <- do.call(rbind,lapply(best,as.data.frame))
    table$complexity <- match(table$family,families)
    eligible <- table$mae<=min(table$mae)*(1+config$simplicity_tolerance)+1e-10
    winner <- table[which(eligible)[which.min(table$complexity[eligible])],]
    selections[[target]] <- winner
    tuning[[target]] <- table
    need <- if(keep_candidates) families else winner$family
    refits <- new.env(parent=emptyenv())
    for(family in need) {
      trial <- best[[family]]
      key <- paste(if(grepl('mixture',family)) 'mixture' else family,trial$lambda,trial$trade_weight)
      if(exists(key,refits,inherits=FALSE)) fitted <- refits[[key]] else {
        fitted <- fit_role_family(family,data[development,],target,trial$lambda,trial$trade_weight,config)
        refits[[key]] <- fitted
      }
      fitted$family <- family
      if(grepl('mixture',family)) fitted$mode <- if(family=='mixture_hard') 'hard' else 'soft'
      if(keep_candidates) candidates[[family]][[target]] <- fitted
      if(family==winner$family) chosen[[target]] <- fitted
    }
    message('Role ',target,': ',winner$family,'; validation MAE ',round(winner$mae,3))
  }
  settings <- config; settings$test_start <- boundary; settings$validation_start <- validation_start
  list(version='role-change-phase-3',models=chosen,candidates=if(keep_candidates) candidates else NULL,
    config=settings,targets=targets,selection=do.call(rbind,selections),tuning=do.call(rbind,tuning),
    latest_training_label=max(data$target_end[development]),
    train_rows=train,validation_rows=validation,development_rows=development)
}

# Drop related feature groups to test whether opportunity measures add value.
# These diagnostic fits never enter the selected model or the saved artifact.
fit_role_ablations <- function(data,config) {
  full <- translation_feature_names()$role_opportunity
  competition <- '(destination_|delta_)(top_usage|high_usage_minutes_share|same_size_minutes_share|available_minutes|available_plays|top_assists)$'
  groups <- list(
    no_added_role=full[!grepl('^role_',full)|full=='role_known_team_change'],
    no_trade_vacancy=full[!grepl('^deal_|^role_(positive_|negative_)',full)],
    no_destination_competition=full[!grepl(competition,full)&
      !grepl('^role_(minutes_room_gap|shots_room_gap|high_usage_competitors|established_creators|usage_load_above_player|assist_load_above_player)$|^deal_(usage_gap|creation_gap)$',full)]
  )
  train <- which(data$target_end<config$validation_start)
  validation <- which(data$verified_trade & data$cutoff>=config$validation_start & data$target_end<config$test_start)
  development <- which(data$target_end<config$test_start)
  fits <- setNames(lapply(groups,function(x) list()),names(groups)); tuning <- list()
  for(group in names(groups)) for(target in c('minutes','usg','ast')) {
    best <- NULL
    for(weight in config$trade_weights) {
      path <- fit_translation_ridge(data[train,],groups[[group]],data[[paste0('change_',target)]][train],
        config$lambda_grid,role_fit_weights(data[train,],weight,config))
      prediction <- role_bounded_delta(predict_translation_ridge(path,data[validation,],config$lambda_grid),data[validation,],target)
      errors <- colMeans(abs(prediction-data[[paste0('change_',target)]][validation]))
      j <- which.min(errors)
      trial <- list(lambda=config$lambda_grid[j],trade_weight=weight,mae=errors[j])
      if(is.null(best)||trial$mae<best$mae-1e-10) best <- trial
    }
    fitted <- fit_translation_ridge(data[development,],groups[[group]],data[[paste0('change_',target)]][development],
      best$lambda,role_fit_weights(data[development,],best$trade_weight,config))
    fitted$kind <- 'ridge'; fits[[group]][[target]] <- fitted
    tuning[[length(tuning)+1L]] <- data.frame(group=group,target=target,features=length(groups[[group]]),
      lambda=best$lambda,trade_weight=best$trade_weight,validation_mae=best$mae)
  }
  list(fits=fits,tuning=do.call(rbind,tuning))
}

# Roles used by a downstream fitting row must be produced by an earlier model.
# Each historical fold also tunes its own model using only earlier labels.
role_change_crossfit <- function(data,config) {
  targets <- c('minutes','usg','ast')
  output <- matrix(NA_real_,nrow(data),3L,dimnames=list(NULL,targets))
  audits <- list()
  starts <- seq(as.Date(sprintf('%s-07-01',config$first_role_fold_year)),config$test_start,by='year')
  for(i in seq_len(length(starts)-1L)) {
    inner <- as.Date(sprintf('%s-07-01',as.integer(format(starts[i],'%Y'))-2L))
    validation <- which(data$cutoff>=inner & data$target_end<starts[i] & data$verified_trade)
    held <- which(data$cutoff>=starts[i]&data$cutoff<starts[i+1L]&data$target_end<config$test_start)
    if(length(validation)<20L||!length(held)) next
    message('Out-of-time roles: ',starts[i])
    model <- fit_role_change(data,config,starts[i],inner,keep_candidates=FALSE)
    stopifnot(model$latest_training_label<min(data$cutoff[held]))
    output[held,] <- predict_role_change(model,data[held,])$delta
    audits[[length(audits)+1L]] <- data.frame(fold_start=starts[i],rows=length(held),
      latest_training_label=model$latest_training_label,earliest_prediction=min(data$cutoff[held]))
  }
  list(delta=output,audit=do.call(rbind,audits))
}

# An augmentation and a no-role control use exactly the same out-of-time rows.
# This prevents an apparent gain caused merely by dropping early warmup rows.
fit_role_downstream <- function(bundle,role_oof,baseline_oof,matched_translator) {
  config <- bundle$config; data <- bundle$observations
  complete <- apply(is.finite(role_oof$delta),1L,all)&apply(is.finite(baseline_oof$predictions),1L,all)
  train <- which(complete & data$transfer & data$target_end<config$validation_start)
  validation <- which(complete & data$verified_trade & data$cutoff>=config$validation_start & data$target_end<config$test_start)
  development <- which(complete & data$transfer & data$target_end<config$test_start)
  if(length(train)<40L||length(validation)<20L) stop('Not enough chronological stacking observations.')
  engineered <- attach_role_predictions(data,role_oof$delta)
  features <- translation_feature_names(); fits <- list(control=list(),augmented=list())
  tuning <- list()
  for(variant in names(fits)) for(target in matched_translator$targets) {
    columns <- c(features$adjustment,if(variant=='augmented') features$downstream_role)
    residual <- data[[paste0('next_',target)]]-baseline_oof$predictions[,target]
    best <- NULL
    for(weight in config$trade_weights) {
      path <- fit_translation_ridge(engineered[train,],columns,residual[train],config$lambda_grid,
        ifelse(data$verified_trade[train],weight,1))
      adjustment <- predict_translation_ridge(path,engineered[validation,],config$lambda_grid)
      for(j in seq_along(config$lambda_grid)) for(scale in config$adjustment_scales) {
        prediction <- translation_clip(baseline_oof$predictions[validation,target]+scale*adjustment[,j],target)
        error <- mean(abs(prediction-data[[paste0('next_',target)]][validation]))
        trial <- list(lambda=config$lambda_grid[j],trade_weight=weight,scale=scale,mae=error)
        if(is.null(best)||error<best$mae-1e-10) best <- trial
      }
    }
    fitted <- fit_translation_ridge(engineered[development,],columns,residual[development],best$lambda,
      ifelse(data$verified_trade[development],best$trade_weight,1))
    fitted$adjustment_scale <- best$scale
    fitted$trade_weight <- best$trade_weight
    fits[[variant]][[target]] <- fitted
    tuning[[length(tuning)+1L]] <- data.frame(variant=variant,target=target,lambda=best$lambda,
      trade_weight=best$trade_weight,scale=best$scale,validation_mae=best$mae)
  }
  summary <- do.call(rbind,tuning); chosen <- list(); selection <- list()
  for(target in matched_translator$targets) {
    control <- summary$validation_mae[summary$target==target & summary$variant=='control']
    augmented <- summary$validation_mae[summary$target==target & summary$variant=='augmented']
    use <- if(augmented<control*(1-config$simplicity_tolerance)) 'augmented' else 'control'
    chosen[[target]] <- fits[[use]][[target]]
    selection[[target]] <- data.frame(target=target,chosen=use,control_mae=control,augmented_mae=augmented)
  }
  list(baseline=matched_translator$baseline,selected=chosen,candidates=fits,
    selection=do.call(rbind,selection),tuning=summary,
    latest_training_label=max(data$target_end[development]),
    train_rows=train,validation_rows=validation,development_rows=development,
    role_fold_audit=role_oof$audit,baseline_fold_audit=baseline_oof$audit)
}

predict_role_augmented_translation <- function(artifact,newdata,variant='selected') {
  model <- artifact$performance
  if('cutoff'%in%names(newdata)&&any(newdata$cutoff<=model$latest_training_label))
    stop('The downstream model was trained after this cutoff.')
  roles <- predict_role_change(artifact$role,newdata)
  data <- attach_role_predictions(newdata,roles$delta)
  fits <- if(variant=='selected') model$selected else model$candidates[[variant]]
  if(is.null(fits)) stop('Only the selected augmentation is saved in the final artifact.')
  targets <- c('minutes','usg','ts','ast')
  prediction <- matrix(NA_real_,nrow(data),4L,dimnames=list(NULL,targets))
  for(target in targets) {
    base <- predict_translation_ridge(model$baseline[[target]],data)[,1L]
    adjustment <- predict_translation_ridge(fits[[target]],data)[,1L]*fits[[target]]$adjustment_scale
    prediction[,target] <- translation_clip(base+ifelse(data$transfer,adjustment,0),target)
  }
  list(role=roles,performance=prediction)
}

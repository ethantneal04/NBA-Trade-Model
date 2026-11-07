# Separate ridge regressions let minutes and each percentage use their own
# shrinkage and outcome scale. There is no random train/test split.
# Run the evaluation script for the full workflow, including the saved artifact.
# glmnet reference: https://glmnet.stanford.edu/articles/glmnet.html

if (!exists('build_translation_data', mode='function')) {
  .model_sources <- Filter(Negate(is.null), lapply(sys.frames(), function(f) f$ofile))
  .model_args <- grep('^--file=', commandArgs(FALSE), value=TRUE)
  .model_dir <- if (length(.model_sources)) dirname(tail(.model_sources,1L)[[1L]]) else
    if (length(.model_args)) dirname(sub('^--file=', '', .model_args[1L])) else 'player performance translation'
  source(file.path(.model_dir, 'player_translation_data.R'), encoding='UTF-8')
}

# Medians, missing indicators, scaling and coefficients are learned from the
# fitting rows only. Neither validation nor test values affect imputation.
translation_matrix <- function(data, features, medians=NULL) {
  x <- as.matrix(data[, features, drop=FALSE]); storage.mode(x) <- 'double'
  x[!is.finite(x)] <- NA_real_
  missing <- is.na(x)
  if (is.null(medians)) medians <- apply(x, 2L, function(v) {
    if (all(is.na(v))) 0 else median(v, na.rm=TRUE)
  })
  for (j in seq_along(features)) x[missing[,j],j] <- medians[j]
  indicators <- missing*1
  colnames(indicators) <- paste0(features, '_missing')
  list(x=cbind(x, indicators), medians=medians)
}

fit_translation_ridge <- function(data, features, y, lambda, weights=rep(1,nrow(data))) {
  design <- translation_matrix(data, features)
  y_mean <- weighted.mean(y, weights)
  y_scale <- sqrt(weighted.mean((y-y_mean)^2, weights))
  if (!is.finite(y_scale) || y_scale < 1e-8) y_scale <- 1
  fit <- glmnet::glmnet(design$x, (y-y_mean)/y_scale, alpha=0, family='gaussian',
                       lambda=sort(unique(lambda), decreasing=TRUE), weights=weights,
                       standardize=TRUE, intercept=TRUE, thresh=1e-9)
  list(fit=fit, features=features, medians=design$medians,
       y_mean=y_mean, y_scale=y_scale,
       x_sd=apply(design$x, 2L, stats::sd), lambda=lambda)
}

predict_translation_ridge <- function(model, data, lambda=model$lambda) {
  if (!requireNamespace('glmnet',quietly=TRUE)) stop('Install glmnet to use the fitted model.')
  x <- translation_matrix(data, model$features, model$medians)$x
  result <- as.matrix(stats::predict(model$fit, newx=x, s=lambda))
  result*model$y_scale + model$y_mean
}

translation_clip <- function(x, target) {
  # TS can exceed 100%; 150% is the box-score maximum for made threes.
  upper <- c(minutes=Inf, usg=100, ts=150, ast=100)[[target]]
  pmin(pmax(x, 0), upper)
}

# Cross-fit residuals by calendar year. A fold can learn only from targets
# completed before its start, including when a 40-game target spans seasons.
# These are observed outcomes, never invented trade responses.
translation_crossfit <- function(data, config, features) {
  targets <- c('minutes','usg','ts','ast')
  output <- matrix(NA_real_, nrow(data), length(targets), dimnames=list(NULL, targets))
  audits <- list()
  starts <- seq(as.Date(sprintf('%s-07-01', config$first_crossfit_year)), config$test_start, by='year')
  for (i in seq_len(length(starts)-1L)) {
    train <- which(data$target_end < starts[i])
    held <- which(data$cutoff >= starts[i] & data$cutoff < starts[i+1L] & data$target_end < config$test_start)
    if (length(train) < 100L || !length(held)) next
    stopifnot(max(data$target_end[train]) < min(data$cutoff[held]))
    inner_boundary <- as.Date(sprintf('%s-07-01',as.integer(format(starts[i],'%Y'))-2L))
    inner_train <- train[data$target_end[train] < inner_boundary]
    inner_validation <- train[data$cutoff[train] >= inner_boundary]
    for (target in targets) {
      # Even the residual model's hyperparameters must be available historically.
      # Tune inside the past fold, rather than borrowing later validation labels.
      lambda <- 1
      if (length(inner_train)>=100L && length(inner_validation)>=30L) {
        path <- fit_translation_ridge(data[inner_train,],features,
          data[[paste0('next_',target)]][inner_train],config$lambda_grid)
        prediction <- translation_clip(predict_translation_ridge(path,data[inner_validation,],config$lambda_grid),target)
        errors <- colMeans(abs(prediction-data[[paste0('next_',target)]][inner_validation]))
        lambda <- config$lambda_grid[which.min(errors)]
      }
      fit <- fit_translation_ridge(data[train,], features, data[[paste0('next_',target)]][train], lambda)
      output[held,target] <- translation_clip(predict_translation_ridge(fit, data[held,])[,1L], target)
    }
    audits[[length(audits)+1L]] <- data.frame(fold_start=starts[i], rows=length(held),
      latest_training_label=max(data$target_end[train]), earliest_prediction=min(data$cutoff[held]))
  }
  list(predictions=output, audit=do.call(rbind,audits))
}

fit_player_translation <- function(bundle) {
  if (!requireNamespace('glmnet', quietly=TRUE)) stop('Install glmnet first.')
  config <- bundle$config; set.seed(config$seed)
  data <- bundle$observations; targets <- c('minutes','usg','ts','ast')
  features <- translation_feature_names()
  # Purge immature targets at both boundaries. A period starting in training
  # but finishing in validation cannot teach the model at the validation start.
  train <- which(data$target_end < config$validation_start)
  validation <- which(data$cutoff >= config$validation_start & data$target_end < config$test_start)
  test <- which(data$cutoff >= config$test_start)
  development <- which(data$target_end < config$test_start)
  if (length(train)<100 || sum(data$verified_trade[validation])<10 || sum(data$verified_trade[test])<10)
    stop('Insufficient observations for the chronological splits.')
  stopifnot(max(data$target_end[train]) < min(data$cutoff[validation]),
            max(data$target_end[development]) < min(data$cutoff[test]),
            !length(intersect(development,test)))
  lambda_a <- setNames(numeric(length(targets)), targets)
  validation_a <- matrix(NA_real_, length(validation), 4L, dimnames=list(NULL,targets))
  tuning <- list(); models_a <- list()
  for (target in targets) {
    message('Tuning baseline: ', target)
    path <- fit_translation_ridge(data[train,], features$baseline, data[[paste0('next_',target)]][train], config$lambda_grid)
    predictions <- translation_clip(predict_translation_ridge(path, data[validation,], config$lambda_grid), target)
    errors <- colMeans(abs(predictions-data[[paste0('next_',target)]][validation]))
    selected <- which.min(errors)
    lambda_a[[target]] <- config$lambda_grid[selected]
    validation_a[,target] <- predictions[,selected]
    tuning[[length(tuning)+1L]] <- data.frame(stage='A', target=target,
      lambda=lambda_a[[target]], trade_weight=1, scale=1, validation_mae=errors[selected],cohort='all_periods')
  }
  message('Building chronological baseline residuals for team-change models')
  crossfit <- translation_crossfit(data, config, features$baseline)
  residual_rows <- which(data$transfer & data$target_end < config$validation_start &
                          apply(is.finite(crossfit$predictions),1L,all))
  all_residual_rows <- which(data$transfer & data$target_end < config$test_start &
                              apply(is.finite(crossfit$predictions),1L,all))
  if (length(residual_rows)<40L) stop('Insufficient out-of-time transfer residuals.')
  held_moves <- which(data$verified_trade[validation])
  validation_move_rows <- validation[held_moves]
  models_b <- list(); models_no_destination <- list(); models_raw <- list()
  validation_predictions <- list(baseline=validation_a[held_moves,,drop=FALSE])
  validation_predictions$no_change <- as.matrix(data[validation_move_rows,paste0('past_',targets)])
  colnames(validation_predictions$no_change) <- targets
  for (variant in c('adjustment','raw_destination','no_destination')) {
    chosen_models <- list()
    variant_predictions <- matrix(NA_real_,length(held_moves),4L,dimnames=list(NULL,targets))
    for (target in targets) {
      best <- NULL
      residual <- data[[paste0('next_',target)]][residual_rows]-crossfit$predictions[residual_rows,target]
      for (trade_weight in config$trade_weights) {
        weights <- ifelse(data$verified_trade[residual_rows],trade_weight,1)
        path <- fit_translation_ridge(data[residual_rows,], features[[variant]], residual, config$lambda_grid, weights)
        adjustments <- predict_translation_ridge(path, data[validation_move_rows,], config$lambda_grid)
        for (j in seq_along(config$lambda_grid)) for (scale in config$adjustment_scales) {
          prediction <- translation_clip(validation_a[held_moves,target] + scale*adjustments[,j], target)
          error <- mean(abs(prediction-data[[paste0('next_',target)]][validation_move_rows]))
          trial <- list(lambda=config$lambda_grid[j], trade_weight=trade_weight, scale=scale,
                        error=error,prediction=prediction)
          if (is.null(best) || error < best$error-1e-10) best <- trial
        }
      }
      message('Refitting ', variant, ': ', target, ' (scale ', best$scale, ')')
      full_residual <- data[[paste0('next_',target)]][all_residual_rows]-crossfit$predictions[all_residual_rows,target]
      chosen <- fit_translation_ridge(data[all_residual_rows,], features[[variant]], full_residual, best$lambda,
          ifelse(data$verified_trade[all_residual_rows],best$trade_weight,1))
      chosen$adjustment_scale <- best$scale; chosen$trade_weight <- best$trade_weight
      chosen_models[[target]] <- chosen
      variant_predictions[,target] <- best$prediction
      tuning[[length(tuning)+1L]] <- data.frame(stage=variant, target=target, lambda=best$lambda,
          trade_weight=best$trade_weight, scale=best$scale, validation_mae=best$error,cohort='verified_trades')
    }
    validation_predictions[[variant]] <- variant_predictions
    if (variant=='adjustment') models_b <- chosen_models else if (variant=='raw_destination')
      models_raw <- chosen_models else models_no_destination <- chosen_models
  }
  for (target in targets) models_a[[target]] <- fit_translation_ridge(data[development,], features$baseline,
      data[[paste0('next_',target)]][development], lambda_a[[target]])
  list(version='phase-2', config=config, targets=targets, baseline=models_a,
       adjustment=models_b, no_destination=models_no_destination,raw_destination=models_raw,
       validation_predictions=validation_predictions,validation_trade_ids=data$record_id[validation_move_rows],
       validation_actual=as.matrix(data[validation_move_rows,paste0('next_',targets)]),
       tuning=do.call(rbind,tuning), crossfit_audit=crossfit$audit,
       split_rows=list(train=train, validation=validation, development=development, test=test),
       residual_rows=all_residual_rows, tuning_residual_rows=residual_rows,
       latest_training_label=max(data$target_end[development]),
       latest_adjustment_label=max(data$target_end[all_residual_rows]),
       software=list(R=R.version.string,glmnet=as.character(utils::packageVersion('glmnet')),
                     data.table=as.character(utils::packageVersion('data.table'))),
       input_hashes=bundle$input_files,
       contract=sprintf('Known destination; %s played appearances; USG/AST are box-score estimates; conditional on completing the target with that team.',config$window))
}

# newdata contains pre-period features plus transfer=TRUE/FALSE. It does not need
# outcomes, player IDs or future game rows. Model B is exactly zero for stayers.
predict_player_translation <- function(model, newdata) {
  n <- nrow(newdata); targets <- model$targets
  baseline <- final <- no_destination <- raw_destination <- matrix(NA_real_, n, length(targets), dimnames=list(NULL,targets))
  moved <- as.logical(newdata$transfer)
  if (length(moved)!=n || anyNA(moved)) stop('Supply transfer=TRUE/FALSE for each row.')
  if ('cutoff' %in% names(newdata) && any(as.Date(newdata$cutoff) <= model$latest_training_label))
    stop('This fitted model contains labels from after the requested prediction cutoff.')
  for (target in targets) {
    baseline[,target] <- translation_clip(predict_translation_ridge(model$baseline[[target]], newdata)[,1L], target)
    b <- predict_translation_ridge(model$adjustment[[target]], newdata)[,1L]*model$adjustment[[target]]$adjustment_scale
    b0 <- predict_translation_ridge(model$no_destination[[target]], newdata)[,1L]*model$no_destination[[target]]$adjustment_scale
    raw <- if (!is.null(model$raw_destination))
      predict_translation_ridge(model$raw_destination[[target]],newdata)[,1L]*model$raw_destination[[target]]$adjustment_scale else rep(0,n)
    final[,target] <- translation_clip(baseline[,target] + ifelse(moved,b,0), target)
    no_destination[,target] <- translation_clip(baseline[,target] + ifelse(moved,b0,0), target)
    raw_destination[,target] <- translation_clip(baseline[,target] + ifelse(moved,raw,0),target)
  }
  list(baseline=baseline, final=final, no_destination=no_destination,raw_destination=raw_destination)
}

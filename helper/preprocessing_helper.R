################################ col_char ################################
## coerce column to character, if it exists
col_char <- function(col, d) {
  if (quo_name(col) %in% names(d)) {
    d <- d %>% 
      mutate(!! quo_name(col) := as.character(!! col))
  }
  
  return(d)
}

################################ clean_names ################################
# clean column names uniformly
clean_names <- function(cnames) {
  cnames <- tolower(cnames)
  cnames <- str_replace_all(cnames, " ","_")
  cnames <- str_replace_all(cnames, "__","_")
  cnames <- str_replace_all(cnames, "optional_","")
}

################################ read_trial_file ################################
# reads trials files and cleans them up

read_trial_file <- function(fname) {
  print(paste0("reading ", fname))
  td <- read_multiformat_file(path = "processed_data/trials_cleaned/", 
                              fname = fname)
  
  originaltd_rows = nrow(td)

  # do some cleanup on variable names that were mangled by data entry
  names(td) <- tolower(names(td))
  names(td) <- str_replace_all(names(td), " ","_")
  
  # vars that should be numeric
  numeric_vars <- intersect(c("trial","total_look","looking_time_s"),  # total_trial_time
                            names(td))
  
  all_vars <- intersect(c("lab", "subject_id", "trial_type", "stimulus", "trial", "looking_time_s",
                          "total_trial_time", "trial_error", "trial_error_type"), 
                        names(td))

  
  # get rid of missing columns
  td_clean <- td %>%
    select(-starts_with("x")) %>%
    mutate_all(as.character) %>%
    mutate_at(vars(numeric_vars), as.numeric) %>%
    select(all_of(all_vars)) %>%
    mutate(file = fname, 
           lab = lab[1])  # some lab fields have gaps, for some reason
  
  lost_cols <- names(td)[!(names(td) %in% names(td_clean)) & (names(td) != "notes")]
        
  row_msg = validate_that(originaltd_rows == nrow(td_clean))
  if (is.character(row_msg)) {
    print(paste0('----->WARNING: DROPPED ROWS: ', originaltd_rows - nrow(td_clean)))
  }
  if (length(lost_cols) > 0) {
    print('----->WARNING: DROPPED COLS: ')
    print(lost_cols)
  }
  
  return(td_clean)
}

################################ read_multiformat_file ################################
# reads files in various formats

read_multiformat_file <- function(path, fname) {
  full_path <- paste0(path,fname)
  
  if (str_detect(fname, ".xlsx")) {
    d <- read_xlsx(full_path)
  } else if (str_detect(fname, ".xls")) {
    d <- read_xls(full_path)
  } else if (str_detect(fname, ".csv")) {
    # https://stackoverflow.com/questions/33417242/how-to-check-if-csv-file-has-a-comma-or-a-semicolon-as-separator
    #L <- readLines(full_path, n = 1)
    #numfields <- count.fields(textConnection(L), sep = ";")
    #if (numfields == 1) {
      d <- read_csv(full_path)
    #} else {
    #  d <- read_csv2(full_path, col_types = cols(parentA_gender = col_character(), ParentA_gender = col_character()))
    #}
  } else if (str_detect(fname, ".txt")) {
    d <- read_tsv(full_path)
  } 
  
  return(d)
}

################################ clean_participant_file ################################
clean_participant_file <- function(fname) {
  print(paste0("reading ", fname))
  pd <- read_multiformat_file(path = "processed_data/participants_cleaned/", 
                              fname = fname)
  
  # mark the original row/col names
  originalpd_rows = nrow(pd)
  originalpd_cols = ncol(pd)
  
  # do some cleanup on variable names that were mangled by data entry
  names(pd) <- clean_names(names(pd))
  
  # get rid of missing columns
  pd <- pd %>% 
    select(-starts_with("x")) %>%
    mutate_all(as.character)
  
  # remove duplicated columns (yes, this is a thing)
  pd <- pd[!duplicated(names(pd), fromLast = TRUE)]
  
  # get col names
  these_cols <- filter(participants_columns, column %in% names(pd))
  
  # rename, select, and re-type these
  # note, NA coercion will lose bad data here, CHECK THIS.
  pd_clean <- pd %>% 
    rename_at(vars(these_cols$column[these_cols$status == "sub"]), 
              ~ these_cols$substitution[these_cols$status == "sub"])
  
  # get them again post-cleaning
  these_cols <- filter(participants_columns, 
                       column %in% names(pd_clean))
  
  
  # report what columns you lost
  lost_cols <- names(pd_clean)[!(names(pd_clean) %in%
                                   participants_columns$column[
                                     participants_columns$status == "include"])]
  
  # select and clean the included columns
  pd_clean %<>%
    select_at(vars(these_cols$column[these_cols$status == "include"])) %>%
    mutate_at(vars(these_cols$column[these_cols$type == "numeric" & 
                                       !is.na(these_cols$type)]), as.numeric) %>%
    filter(!is.na(lab))
  
  # throw a message if rows are being dropped
  row_msg = validate_that(originalpd_rows == nrow(pd_clean))
  if (is.character(row_msg)) {
    print(paste0('----->WARNING: DROPPED ROWS: ', originalpd_rows - nrow(pd_clean)))
  }
  
  # throw a message if columns are being dropped
  col_msg = validate_that(originalpd_cols == ncol(pd_clean))
  if (is.character(col_msg)) {
    print(paste0('----->WARNING: DROPPED COLS: ', originalpd_cols - ncol(pd_clean)))
  }
  
  
  if (length(lost_cols) > 0) {
    print(lost_cols)
  }
  
  # add filename last so it doesn't mess up column checking
  pd_clean %<>% 
    mutate(file = fname)
  
  return(pd_clean)
}

################################ lang_exp_to_numeric ################################
## removes excess text from language exposure columns and converts to numeric

lang_exp_to_numeric <- function(my_column){
  x <- as.numeric(str_replace_all(my_column, "%", "") %>%
                    str_replace_all("% in books", ""))
}


################################ exclude_by ################################
# excludes on a column and outputs the percentages for exclusion
# - flag return_pcts means you get a list with the data and other exclusion stats
# - flag action flips the column polarity

exclude_by <- function(d, col, setting = "all", action = "exclude", 
                       return_pcts = FALSE, quiet = TRUE) {
  
  # if this is an include-by variable, flip polarity
  if (action == "include") {
    d <- d %>%
      mutate(!! quo_name(col) := ! (!! col))
  }
  
  if (!quiet) print(paste("filtering by", quo_name(col)))
  
  percent_trial <- d %>%
    ungroup %>%
    summarise(trial_sum = sum(!! col, na.rm=TRUE),
              trial_mean = mean(!! col, na.rm=TRUE)) 
  
  percent_sub <- d %>%
    group_by(lab, subid) %>%
    summarise(any = any(!! col), 
              all = all(!! col)) %>%
    ungroup %>%
    summarise(any_sum = sum(any, na.rm=TRUE), 
              any_mean = mean(any, na.rm=TRUE), 
              all_sum = sum(all, na.rm=TRUE), 
              all_mean = mean(all, na.rm=TRUE))
    
  if (!quiet) {
    print(paste("This variable excludes", percent_trial$trial_sum, "trials, which is ", 
                round(percent_trial$trial_mean*100, digits = 1), "% of all trials."))
    
    if (setting == "any") {
      print(paste(percent_sub$any_sum, " subjects,", 
                  round(percent_sub$any_mean*100, digits = 1),
                  "%, have any trials where", quo_name(col), "is true."))
    } else if (setting == "all") {
      print(paste(percent_sub$all_sum, " subjects,", 
                  round(percent_sub$all_mean*100, digits = 1),
                  "%, have all trials where", quo_name(col), "is",
                  ifelse(action == "include", "true:", "false:"), 
                  action))
    }
  }
  
  if (action=="NA out") {
    d <- mutate(d, 
                looking_time = ifelse(!! col, NA, looking_time))
  } else {
    d <- filter(d, !( !! col))
  }
  
  if (return_pcts) {
    return(list(data = d, 
                percents = percent_sub, 
                percent_trials = percent_trial))
  } else {
    return(d)
  }
}
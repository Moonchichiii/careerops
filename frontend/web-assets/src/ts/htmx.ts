import htmx from "htmx.org";

htmx.config.allowEval = false;
htmx.config.allowScriptTags = false;
htmx.config.includeIndicatorStyles = false;
htmx.config.historyRestoreAsHxRequest = false;
htmx.config.selfRequestsOnly = true;
htmx.config.reportValidityOfForms = true;

document.documentElement.dataset.htmx = "ready";

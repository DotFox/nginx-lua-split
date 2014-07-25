local redis = require("redis")

math.randomseed(os.time())

-- Gap for cookie expire time, 1 week
local cookie_gap = 7*24*60*60

local simpleFormForEditExperiment = [[
  <body>
  <script>
  var submit = function() {
    var xmlHTTP = null;
    var http = location.protocol;
    var slashes = http.concat("//");
    var host = slashes.concat(window.location.hostname);
    var encode_params = function(data) {
       var ret = [];
       for (var d in data)
          ret.push(encodeURIComponent(d) + "=" + encodeURIComponent(data[d]));
       return ret.join("&");
    }
    var get_params = function() {
      var params = {
        name:       document.getElementById("name").value,
        a:          document.getElementById("a").value,
        b:          document.getElementById("b").value,
        use_aff:    document.getElementById("use_aff").value,
        stop_after: document.getElementById("stop_after").value
      }
      return params
    }
    var theUrl = host.concat("/api/split/?").concat(encode_params(get_params()));
    xmlHttp = new XMLHttpRequest();
    xmlHttp.open( "GET", theUrl, false );
    xmlHttp.send( null );
    return xmlHttp.responseText;
  }
  </script>
  <div>
    <h1>Configure A/B Experiment</h1>
    <input id="name" type="text" placeholder="Experiment Name">
    <input id="a" type="text" placeholder="A quotum">
    <input id="b" type="text" placeholder="B quotum">
    <input id="use_aff" type="text" placeholder="Is affiliate accepted">
    <input id="stop_after" type="text" placeholder="Stop after">
    <input type="submit" onClick="submit();">
  </div>
  </body>
]]

local function connectRedis()
  local rds = redis:new()
  rds:set_timeout(50)
  local ok, err = rds:connect("127.0.0.1", 6379)
  if not ok then
    return nil
  end
  return rds
end

local function serializeExperiment(exp)
  return exp.a .. "|" .. exp.b .. "|" .. exp.name .. "|" .. exp.use_aff .. "|" .. exp.stop_after
end

local function parseExperiment(exp)
  local m, err = {}, nil
  if exp then
    if type(exp) == "string" then
      local pattern = "(?<a>[0-9]+)[|](?<b>[0-9]+)[|](?<name>[_a-z]+)[|](?<use_aff>[a-z]+)[|](?<stop_after>[0-9]+)"
      m, err = ngx.re.match(exp, pattern)
    elseif type(exp) == "table" then
      stop_after = os.time() + tonumber(exp.arg_stop_after) * 60 * 60
      m = {
        a          = exp.arg_a,
        b          = exp.arg_b,
        name       = exp.arg_name,
        use_aff    = exp.arg_use_aff,
        stop_after = stop_after
      }
    end
  end
  return m
end

local function getExperiment(exp)
  local experiment, err = {}, nil
  if exp then
    experiment = parseExperiment(exp)
  else
    local rds = connectRedis()
    experiment, err = rds:get("experiment")
    if type(experiment) == "string" then
      experiment = parseExperiment(experiment)
    elseif type(experiment) == "userdata" then
      experiment = {}
    end
    rds:close()
  end
  return experiment, err
end

local function saveExperiment(exp)
  local message = "Experiment not saved."
  local rds = connectRedis()
  local str_experiment = serializeExperiment(exp)
  local ok, err = rds:set("experiment", str_experiment)
  if ok == "OK" then
    message = "Experiment " .. exp.name .. " saved."
    ok, err = rds:expire("experiment", exp.stop_after - os.time())
    if ok == 1 then
      message = message .. "\nExperiment will expired after " .. exp.stop_after - os.time() .. " seconds."
    else
      message = message .. "\nWarning! TTL for experiment not set."
    end
  end
  rds:close()
  return message
end

local function isValid(experiment)
  local valid = true
  local n = 0
  for k, v in pairs(experiment) do
    n = n + 1
    if not v then
      valid = false
    end
  end
  if n == 0 then
    valid = false
  end
  return valid
end


local function needAffiliateExperiment(marker, use_aff)
  if marker and (string.match(marker, "^%d%d%d%d%d.-.") or string.match(marker, "^%d%d%d%d%d.-$")) then
    if use_aff == "true" then
      return true
    elseif use_aff == "false" then
      return false
    end
  end
  return true
end

local function isIrregularBot(product)
  local result = false
  if not product then
    -- pass
  elseif ngx.re.find(product, "Mediapartners-Google", "joi") then
    result = true
  elseif ngx.re.find(product, "NewRelicPinger", "joi") then
    result = true
  elseif ngx.re.find(product, "facebookexternalhit", "joi") then
    result = true
  end
  return result
end

local function isBot()
  local result = false
  local user_agent = ngx.req.get_headers()["User-Agent"]
  local pattern = [[^(?<product>[^/\s]+)?/?(?<version>[^\s]*)?(\s\((?<comment>[^)]*)\))?]]
  local m, err = ngx.re.match(user_agent, pattern)
  if err then
    result = true
  elseif m then
    local from, to, err
    for k, v in pairs(m) do
      if v then
        if ngx.re.find(v, "bot", "joi") then
          result = true
        end
      end
    end
    if not result then
      result = isIrregularBot(m.product)
    end
  end
  return result
end

local function rollDice(a, b)
  local x = math.random(0, 100)
  if x > 100 - tonumber(a) then
    return "a"
  elseif x < tonumber(b) then
    return "b"
  end
  return "default"
end

local function saveCookie(exp, test_rule)
  ngx.header["Set-Cookie"] = {
    "test_name=" .. exp.name .. "; path=/; Expires=" .. ngx.cookie_time(exp.stop_after + cookie_gap) .. ";",
    "test_rule=" .. test_rule .. "; path=/; Expires=" .. ngx.cookie_time(exp.stop_after + cookie_gap) .. ";",
    "test_stop=" .. exp.stop_after .. "; path=/; Expires=" .. ngx.cookie_time(exp.stop_after + cookie_gap) .. ";"
  }
end

local function getTestKeyword(user_test_name, user_test_rule, user_test_stop, user_marker)
  local test_rule = "default"
  local current_exp, err = getExperiment()
  if not isBot() and current_exp.name then
    if needAffiliateExperiment(user_marker, current_exp.use_aff) then
      if current_exp.name == user_test_name then
        test_rule = user_test_rule
        if current_exp.stop_after ~= user_test_stop then
          saveCookie(current_exp, test_rule)
        end
      else
        test_rule = rollDice(current_exp.a, current_exp.b)
        saveCookie(current_exp, test_rule)
      end
    end
  end
  return test_rule
end

_M = {}

function _M.saveExperiment()
  local exp, err = getExperiment(ngx.var)
  local message = "Experiment not configured."
  if not err and isValid(exp) then
    message = saveExperiment(exp)
  end
  return message
end

function _M.renderExperimentForm()
  return simpleFormForEditExperiment
end

function _M.getQuotum(keyword)
  local exp, err = getExperiment()
  if not err and isValid(exp) then
    if not keyword then
      return math.floor(ngx.var.min_instances * (1 - (exp.a + exp.b)/100))
    else
      return math.floor(ngx.var.min_instances * (exp[keyword]/100))
    end
  end
  return ngx.var.min_instances
end

function _M.configureUser()
  local test_rule = ngx.var.cookie_test_rule
  local test_name = ngx.var.cookie_test_name
  local test_stop = ngx.var.cookie_test_stop
  local marker = ngx.var.arg_marker or ngx.var.cookie_marker
  return getTestKeyword(test_name, test_rule, test_stop, marker)
end

return _M

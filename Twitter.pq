section Twitter;

client_application = Expression.Evaluate(Text.FromBinary(Extension.Contents("client_application")));
windowWidth = 1000;
windowHeight = 1000;
requestTokenUrl = "https://api.twitter.com/oauth/request_token";
authenticateUrl = "https://api.twitter.com/oauth/authenticate";
accessTokenUrl = "https://api.twitter.com/oauth/access_token";


OAuth.Request = (isPost, url, authProps, otherProps, secret1, secret2, optional accept) =>
    let
        method = if isPost then "POST" else "GET",
        combined = authProps & otherProps & [
            oauth_signature_method="HMAC-SHA1",
            oauth_nonce = Text.NewGuid(),
            oauth_timestamp = Number.ToText(Number.Round(Duration.TotalSeconds(DateTimeZone.UtcNow() - #datetimezone(1970, 1, 1, 0, 0, 0, 0, 0)))),
            oauth_version = "1.0"
        ],
        fieldNames = List.Sort(Record.FieldNames(combined)),
        pairs = List.Transform(fieldNames, (f) => f & "=" & Uri.EscapeDataString(Record.Field(combined, f))),
        combinedpairs = Text.Combine(pairs, "&"),
        baseString = method & "&" & Uri.EscapeDataString(url) & "&" & Uri.EscapeDataString(combinedpairs),
        compositeKey = Uri.EscapeDataString(secret1) & "&" & Uri.EscapeDataString(secret2),
        signature = Binary.ToText(Crypto.CreateHmac(CryptoAlgorithm.SHA1, Text.ToBinary(compositeKey), Text.ToBinary(baseString)), BinaryEncoding.Base64),
        withSignature = combined & [oauth_signature = signature],
        allNames = Record.FieldNames(withSignature),
        otherNames = Record.FieldNames(otherProps),
        included = List.Select(allNames, each not List.Contains(otherNames, _)),
        includedPairs = List.Transform(included, (f) => f & "=""" & Uri.EscapeDataString(Record.Field(withSignature, f)) & """"),
        auth = [Authorization = "OAuth " & Text.Combine(includedPairs, ", ")],
        headers = if accept = null then auth else auth & [Accept=accept],
        queryString = Uri.BuildQueryString(otherProps),
        options = if isPost then [Headers = [#"Content-type" = "application/x-www-form-urlencoded"] & headers, Content = Text.ToBinary(queryString)] else [Headers = headers],
        actualUrl = if isPost or Text.Length(queryString) = 0 then url else url & "?" & queryString,
        result = Web.Contents(actualUrl, options & [ManualCredentials=true])
    in
        result;

Uri.FromParts = (parts) =>
    let
        port = if (parts[Scheme] = "https" and parts[Port] = 443) or (parts[Scheme] = "http" and parts[Port] = 80) then "" else ":" & Text.From(parts[Port]),
        div1 = if Record.FieldCount(parts[Query]) > 0 then "?" else "",
        div2 = if Text.Length(parts[Fragment]) > 0 then "#" else "",
        uri = Text.Combine({parts[Scheme], "://", parts[Host], port, parts[Path], div1, Uri.BuildQueryString(parts[Query]), div2, parts[Fragment]})
    in
        uri;

OAuth.Get = (url, authProps, secret1, secret2, optional accept) =>
    let
        parts = Uri.Parts(url),
        otherProps = parts[Query],
        url2 = Uri.FromParts(parts & [Query=[]])
    in
        OAuth.Request(false, url2, authProps, otherProps, secret1, secret2, accept);

GetRequestToken = () =>
    let
        auth = [oauth_callback = client_application[CallbackUrl], oauth_consumer_key = client_application[ClientId]],
        Response = OAuth.Request(true, requestTokenUrl, auth, [], client_application[ClientSecret], ""),
        Parts = Uri.Parts("http://localhost?" & Text.FromBinary(Response))[Query]
    in
        Parts;

StartLogin = (resourceUrl, state, display) =>
    let
        Token = GetRequestToken(),
        AuthorizeUrl = authenticateUrl & "?oauth_token=" & Uri.EscapeDataString(Token[oauth_token])
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = client_application[CallbackUrl],
            WindowHeight = windowHeight,
            WindowWidth = windowWidth,
            Context = Token
        ];

FinishLogin = (context, callbackUri, state) =>
    let
        Token = context,
        QueryParts = Uri.Parts(callbackUri)[Query],
        auth = [oauth_token = Token[oauth_token], oauth_consumer_key = client_application[ClientId]],
        verifier = [oauth_verifier = QueryParts[oauth_verifier]],
        Response = OAuth.Request(true, accessTokenUrl, auth, verifier, client_application[ClientSecret], Token[oauth_token_secret]),
        Parts = Uri.Parts("http://localhost?" & Text.FromBinary(Response))[Query]
    in
        Parts & [access_token="dummy"];

Table.GenerateByPage = (getNextPage as function) as table =>
    let
        listOfPages = List.Generate(
            () => getNextPage(null),
            (lastPage) => lastPage <> null,
            (lastPage) => getNextPage(lastPage)
        ),
        tableOfPages = Table.FromList(listOfPages, Splitter.SplitByNothing(), {"Column1"}),
        firstRow = tableOfPages{0}?
    in
        if (firstRow = null) then
            Table.FromRows({})
        else
            Value.ReplaceType(
                Table.ExpandTableColumn(tableOfPages, "Column1", Table.ColumnNames(firstRow[Column1])),
                Value.Type(firstRow[Column1])
            );

Columns = {"metadata", "created_at", "id", "id_str", "text", "source", "truncated", "in_reply_to_status_id", "in_reply_to_status_id_str", "in_reply_to_user_id", "in_reply_to_user_id_str", "in_reply_to_screen_name", "user", "geo", "coordinates", "place", "contributors", "retweet_count", "favorite_count", "entities", "favorited", "retweeted", "possibly_sensitive", "lang", "retweeted_status"};

GetOneSearchPage = (url, parameters) =>
    let
        credential = Extension.CurrentCredential(),
        auth = [oauth_consumer_key = client_application[ClientId], oauth_token = credential[Properties][oauth_token]],
        response = OAuth.Request(false, url, auth, parameters, client_application[ClientSecret], credential[Properties][oauth_token_secret], "application/json"),
        json = Json.Document(response),
        table = Table.FromList(json[statuses], Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        expanded = Table.ExpandRecordColumn(table, "Column1", Columns, Columns)
    in
        expanded;

// Apparently the paging code is totally broken :(
GetSearchResults = (searchText, count) => Table.GenerateByPage((previous) =>
    let
        url = "https://api.twitter.com/1.1/search/tweets.json",
        parameters = if previous = null then [q = searchText, count = "100"] else Value.Metadata(previous)[Next],
        nextCount = if previous = null then count else Value.Metadata(previous)[Count] - 1,
        page = if previous = null then GetOneSearchPage(url, parameters) else null
    in
        page);

[DataSource.Kind = "Twitter"]
shared Twitter.Search = Value.ReplaceType(
    GetSearchResults,
    type function (searchText as (type text meta [DataSource.Path=false]), count as (type number meta [DataSource.Path=false])) as any);

Twitter = [
    Authentication=[OAuth=[StartLogin=StartLogin, FinishLogin=FinishLogin]]
];

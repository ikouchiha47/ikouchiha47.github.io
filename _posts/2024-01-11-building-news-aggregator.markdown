---
layout: post
title: "News aggregator"
subtitle: "Building a news aggregator"
description: "Building a news aggregator in go"
date: 2024-01-11 00:00:00
background_color: '#da46ff'
---

# News Aggregator: Fetching and Unifying News from Different Sources

The task at hand was to create a service that aggregates news from different sources. Rather than making individual HTTP requests for each news provider, we opted for a more scalable and configurable approach. The solution involves using a YAML configuration file to specify different news sources, their endpoints, parameters, and the transformation rules for unifying the data.

## YAML Configuration

The YAML configuration file outlines the news sources, their URLs, HTTP methods, parameters, and the rules for extracting relevant information. Let's break down the key components:

```yaml
news:
  sources:
    - url: "https://api.marketaux.com/v1/news/all"
      method: get
      limit: 10
      params:
        api_token: {{ .MauxApiToken }}
        countries: in
        filter_entities: true
        limit: 10
        language: en
      iterator: data
      fields:
        - key: author
          value: 'MarketAux'
          static: true
        - key: provider
          value: data.#.source
          iter: true
          modifier: "split(.) |> first |> lower |> title"
          datatype: string
        - key: title
          value: data.#.title
          iter: true
        - key: description
          value: data.#.description
          iter: true
        - key: url
          value: data.#.url
          iter: true
        - key: image_url
          value: data.#.image_url
          iter: true
        - key: content
          value: data.#.description
          iter: true
        - key: published_at
          value: data.#.published_at
          iter: true

    - url: "https://newsapi.org/v2/everything"
      limit: 20
      params:
        apiKey: {{ .NewsApiKey }}
        sources: "the-hindu,the-times-of-india"
        q: bank
      iterator: articles
      fields:
        # ... (fields configuration)
```

The configuration allows for multiple news sources, each with its own set of parameters and transformation rules.

The above YAML is used as a template, so that the `API Tokens` can be replaced during runtime, from config.


## Go Code Implementation

The Go code for this News Aggregator is designed to be modular and extensible. Let's look at some key components:

### Structs for News Response

```go
type NewsResponse struct {
	Author      string `json:"author"`
	Provider    string `json:"provider"`
	Title       string `json:"title"`
	Description string `json:"description"`
	URL         string `json:"url"`
	ImageURL    string `json:"image_url"`
	Content     string `json:"content"`
	PublishedAt string `json:"published_at"`
}
```

This struct represents the unified format for news responses.

### News Aggregator Struct

```go
type NewsAggregator struct {
	News RootObj `yaml:"news"`
}

type RootObj struct {
	Sources []Source `yaml:"sources"`
}

type Source struct {
	URL      string                 `yaml:"url"`
	Method   string                 `yaml:"method"`
	Limit    int                    `yaml:"limit"`
	Fields   []Fields               `yaml:"fields"`
	Params   map[string]interface{} `yaml:"params,omitempty"`
	Iterator *string                `yaml:"iterator"`
}
```

The `NewsAggregator` struct mirrors the structure of the YAML configuration.

### Fetching and Parsing News

The `NewsFetcher` and `NewsParser` structs handle fetching and parsing news from different sources. The `FetchNewsUsingConfig` function orchestrates the parallel fetching of news from multiple sources.

```go
type NewsFetcher struct {
	Client *http.Client
}

func (nf *NewsFetcher) Fetch(source Source) (response string, err error) {
	method := source.Method

	if len(method) == 0 {
		method = "get"
	}

	method = strings.ToUpper(method)
	log.Println(method, source.URL)

	req, err := http.NewRequest(method, source.URL, nil)
	if err != nil {
		log.Printf("failed to build request to newsapi. Reason: %v \n", err)
		return response, err
	}

	q := req.URL.Query()

	for key, value := range source.Params {
		q.Add(key, fmt.Sprintf("%v", value))
	}

	req.URL.RawQuery = q.Encode()

	b, err := httputil.DumpRequest(req, true)
	if err != nil {
		panic(err)
	}

	res, err := nf.Client.Do(req)
	if err != nil {
		log.Printf("failed to make request to newsapi. Reason: %v \n", err)
		return response, err
	}
	defer res.Body.Close()

	body, err := io.ReadAll(res.Body)
	if err != nil {
		log.Printf("failed to make request to newsapi. Reason: %v \n", err)
		return response, err
	}

	response = string(body)
	// log.Println("body ", bodyStr)

	if res.StatusCode >= 400 {
		return response, errors.New("http_request_failed")
	}

	// log.Printf("response received %v\n", response)
	log.Println("response length ", len(response))
	return response, nil
}

```

### `ParseModifier` Function

The `ParseModifier` function in the `NewsParser` struct is responsible for parsing the modifier provided in the YAML configuration. This function splits the modifier into different parts and identifies the functions that need to be applied during the data transformation.

```go
type NewsParser struct {
	fetcher Fetcher
}

func NewNewsParser(fetcher Fetcher) *NewsParser {
	return &NewsParser{
		fetcher: fetcher,
	}
}
func (np *NewsParser) ParseModifier(str string) ([]interface{}, error) {
    parts := strings.Split(str, "|>")
	functions := make([]interface{}, 0, len(parts))

	tFuncs := NewTemplateFuncs().Funcs()

	log.Println(tFuncs)

	for _, part := range parts {
		part = strings.TrimSpace(part)

		match := regexp.MustCompile(`^(\w+)\((.*?)\)`).FindStringSubmatch(part)
		if match == nil {
			log.Println("1 airty function")

			f, ok := tFuncs[part]
			if !ok {
				return nil, fmt.Errorf("unknown function: %s", part)
			}

			functions = append(functions, f)

			continue
		}

		log.Println("2 airty function ", match[1], match[2])
		f := tFuncs[match[1]]
		if curryable, ok := f.(func(string) StrSliceable); ok {
			functions = append(functions, curryable(match[2]))
		} else {
			return nil, fmt.Errorf("function %s is not curryable", match[1])
		}
	}

	return functions, nil
}
```

### Data Retrieval with `gjson`

The `gjson` library is employed to parse the JSON response obtained from the news sources. The `ParseSource` function in the `NewsParser` struct utilizes `gjson` to retrieve the number of records based on the iterator and iterates over the fields, replacing `#` with the index to fetch the proper values.


```go
func (np *NewsParser) ParseSource(source Source) (ns NewsResponseData, err error) {
    // Iterate over length
	// For each field paramtere, if iter: true, then replace # with index
	// Call gjson.Get on the item
	// Build the struct and add to list of response

	count := gjson.Get(bodyStr, fmt.Sprintf("%s.#", iter)).Int()
	log.Println("count of data", count)

	responses := []map[string]interface{}{}

	for i := int64(0); i < count; i += 1 {
		nresp := map[string]interface{}{}

		for _, field := range source.Fields {
			if field.Static {
				nresp[field.Key] = field.Value
				continue
			}

			valueTpl := field.Value

			if field.ShouldIter && strings.Contains(valueTpl, "#") {
				gjsonKey := strings.Replace(valueTpl, "#", fmt.Sprintf("%d", i), 1)
				nresp[field.Key] = gjson.Get(bodyStr, gjsonKey).Value()
			} else {
				nresp[field.Key] = gjson.Get(bodyStr, valueTpl).Value()
			}

			if field.Modifier == nil {
				continue
			}

			value := nresp[field.Key]
			dataType := field.DataType
			if dataType == nil {
				strType := DataTypeString
				dataType = &strType
			}

			log.Printf("response value %+v\n", value)

			// modify the initial value with the modifier
			result := value

			switch *dataType {
			case DataTypeString:
				funcs, err := np.ParseModifier(*field.Modifier)
				if err != nil {
					log.Printf("invalid data type. received %+v\n", err)
					return ns, err
				}

				for i := 0; i < len(funcs); i++ {
					f := funcs[i]

					switch f := f.(type) {
					case StrSliceable:
						// log.Printf("str sliceable %+v\n", result)
						result = f(result.(string))
					case func([]string) string:
						// log.Printf("str slice %+v\n", result)
						result = f(result.([]string))
					case func(string) string:
						// log.Printf("point string %+v\n", result)
						result = f(result.(string))
					default:
						log.Printf("failed to match modifier func type %#V\n", f)
						return ns, ErrUndefinedModifier
					}
				}

			default:
				return ns, ErrUnsupportedDataType
			}

			nresp[field.Key] = result
		}

		responses = append(responses, nresp)
	}

	ns.Source = source
	ns.Responses = responses

	return ns, nil
}
```

### `FetchNewsFromConfig` function to get news

This fetches the news from multiple sources in parallel. Although we could have had a list of workers 

```go

func (np *NewsParser) FetchNewsUsingConfig(
	ctx context.Context,
	fileName string,
	data map[string]interface{},
) ([]map[string]interface{}, error) {
	tmpl, err := template.New("newsources.yaml").ParseFiles(fileName)
	if err != nil {
		panic(err)
	}

	var buffer bytes.Buffer
	err = tmpl.Execute(&buffer, data)
	if err != nil {
		log.Println("failed to execute template", err)
		panic(err)
	}

	ns := &NewsAggregator{}

	err = yaml.Unmarshal(buffer.Bytes(), &ns)
	if err != nil {
		panic(err)
	}


    // Create n waitgroups where n = number of news sources
	var wg sync.WaitGroup
	wg.Add(len(ns.News.Sources))

	var responsesChan = make(chan NewsResponseData, len(ns.News.Sources))

	for _, source := range ns.News.Sources {
		go func(w *sync.WaitGroup, src Source) {
			defer w.Done()
			resp, err := np.ParseSource(src)
			if err != nil {
				log.Println("failed to fetch news from source ", src.URL)
				return
			}

			responsesChan <- resp
		}(&wg, source)
	}

    // Wait for all the responses to complete 
	wg.Wait()
	close(responsesChan)

	responses := []map[string]interface{}{}

    // Aggregate all the responses and put it inside responses
	for resps := range responsesChan {
		log.Println(len(resps.Responses), " news items received from", resps.Source.URL)
		responses = append(responses, resps.Responses...)
	}

	log.Println(len(responses), " total news received")
	return responses, nil
}
```

Now you can use a cache to store the response data. You can set the cache expiry based on the `limit` in the config yaml file.

## Conclusion

This News Aggregator provides a flexible and scalable solution for fetching and unifying news from diverse sources. The YAML configuration allows for easy customization, making it adaptable to various use cases. The Go code's modular design ensures maintainability and extensibility, enabling future enhancements and feature additions.

By centralizing news from different sources into a unified format, users can effortlessly access a curated stream of information. This News Aggregator serves as a foundation for creating more sophisticated news aggregation services tailored to specific needs and preferences.

`Thank you`

---
layout: post
title: "Go getters"
subtitle: "Generating getters in go with go generate"
date: 2023-11-20 00:00:00
background_color: '#000'
---

In this article we will explore how to beat Intellij.

Not their trial version, but by trying to replicate the `Create Getters and Setters` functionality.

This is going to be a fairly technical article, because I have a problem stitching words together to make a conversation.  

<p>&nbsp;</p>

### Backstory:

What we are trying to do here is to generate `Get`-er method for the fields in a struct.

Why you ask?

For one, I wanted to use the golang's ast package and i was quite impressed by the stringer package.

And secondly, as I keep implementing the `config` loader. I find myself at odds with a couple of approaches:

~~~ go
package config

type Config struct {
  Env string `mapstructure:"ENV"`
}

var (
  once sync.Once
  cfg Config
)

func Load(paths ..string) {
  once.Do(func() {
    // config fetching code
    cfg = Config{}
  })
}

func GetConfig() Config {
  return cfg
}
~~~

or

~~~ go
package config

var (
  mu sync.Mutex
  cfg Config
)

func Load(paths ...string) {
  mu.Lock()
  defer mu.Unlock()
  
  cfg = Config{}
}

func GetConfig() Config {
  mu.Lock()
  defer mu.Unlock()
 
  return cfg
}
~~~

or,  

```go
package config

var Cfg Config
```

Apart from the last one, since the config loading happens only once at the start of app, these approaches work fine mostly.

But whatif we wanted to truly and unnecessarily encapsulate the config params in the struct?

One way that stuck out was using `private` fields in struct and `public` getter methods. But the problem was writing these methods.

Intellij has an in editor functionality, and I thought this was a good opportunity to try to generate the methods on the field.

In the end it would look like this

```go
//go:generate geterator -type=Config -private
```

<p>&nbsp;</p>

### Implementation details:

We need to know a couple go libraries for this.

- `go/ast`
- `go/format`
- `go/parser`
- `go/token`
- `golang.org/x/tools/go/packages`


And [go generate](https://go.dev/blog/generate)


In short, we want to iterate through the golang package, and find the struct which matches our provided struct name, and then iterate through the fields and write the Getter method to an output buffer.

This probably isn't the best approach, but works for my other projects for now.


A quick glimpse into how the `go generate` works. We write a simple code to test

{% highlight go %}
package main

//go:generate echo "hello world"
func main() {}
{% endhighlight %}

If we run this like `go generate ./...` , this would give us hello world in the terminal.

So given this, we can imagine that if we have an executable, then whatever comes after the go:generate gets executed like a normal executable would. (Approximately like that, but not exactly)


Now we just need to build a golang library, that will take an input as such:

{% highlight shell %}
./executable -type=StructName -private .
{% endhighlight %}

- type takes the struct name as parameter
- private indicates that we want to expose unexported fields
- the `.` indicates the directory to search in.


__Now for the main part.__

Using the go [packages library](https://pkg.go.dev/golang.org/x/tools/go/packages), we will load the golang code from the directory for analysis.

Each package object has couple of information, but the important ones are. Types, Syntax (containing parsed syntax tree), GoFiles.


This is how we can load the packages and iterate over the exported `Types` to find the package name containing the `-type` parameter value

```go
var (
  typeName = flag.String("type", "", "struct names. must be present in go file. -type=Config") 
)

flag.Parse()
dir := flag.Arg(0)

pkgs, err := packages.Load(cfg, dir)
if err != nil {
  log.Fatal(err)
}

var pkg *packages.Package

for _, p := range pkgs {
  if p.Types == nil {
    // if no exported symbols, leave it
    continue
  }

  for _, f := range p.Syntax {
    ast.Inspect(f, func(node ast.Node) bool { // Look for a type definition with the given name. 
      if typeSpec, ok := node.(*ast.TypeSpec); ok {
        if typeSpec.Name.Name == *typeName {
          pkg = p
          return false // we found a match. so skipping rest.
        }
      }
      return true
    })

    // we found the desired package of the struct.
    if pkg != nil {
      break
    }
  }
}

if pkg == nil {
  log.Fatalf("error: type %q not found\n", *typeName)
}
 // we found the desired package of the struct.
```

`ast.Inspect` iterates over each of these `ast.Node` and calls the `callback` function. If the callback function returns true, it invokes the callback function recursively on its children.


_Basically in javascript terms, returning false, stops the event propagation._


Given that, we now need to modify the `callback function` to identify if the node is a struct, we can get each field and write the getter function as string to a buffer.


```go
var exportPrivate = flag.Bool("private", false, "should you want to include private fields in struct as well")
var buf = buffer.Bytes{}

if structType, ok := typeSpec.Type.(*ast.StructType); ok {
  for _, field := range structType.Fields.List { 
     if field.Names == nil { // i know, but runtime check.
       continue
     }
 
     f := field.Names[0]

     if !(*exportPrivate) && !f.IsExported() { continue } 

     fieldType := exprToString(field.Type)

     buf.WriteString(fmt.Sprintf("func (c %s) Get%s() %s {\n", *typeName, toUpperFirst(f.Name), fieldType))
     buf.WriteString(fmt.Sprintf("return c.%s\n", f.Name))
     buf.WriteString("}\n")
   }
}
```

And et volla. We now have the receipie for make an executable that we can use to generate some get methods.

<p>&nbsp;</p>

### Usage instructions

Now to implement this. We will first create a directory and do a go mod init in it.

<img src="/img/posts/generating-getters-in-go_dirtree.png"/>


This is how your folder looks like. And in the `utils/util.go` we have

{% highlight go %}
package util


//go:generate go run github.com/go-batteries/geterator -type=Foo
type Foo struct {
    Name   string
    hidden bool
}


//go:generate go run github.com/go-batteries/geterator -type=Bar -private
type Bar struct {
    Drinks []int
    Namer  Foo
    hidden bool
}


type Nothing struct {
    Nothing string
}
{% endhighlight %}

On running `go generate ./...` It gives us two files.


// Code generated by "go generate"; DO NOT EDIT

{% highlight go %}
package utils


func (c Bar) GetDrinks() []int {
    return c.Drinks
}
func (c Bar) GetNamer() Foo {
    return c.Namer
}
func (c Bar) GetHidden() bool {
    return c.hidden
}

// utils/bar_gen.go 



// Code generated by "go generate"; DO NOT EDIT


package utils


func (c Foo) GetName() string {
    return c.Name
}
{% endhighlight %}

You can find the implementation here [geterator](github.com/go-batteries/geterator)

<p>&nbsp;</p>

### Footnotes

For implementation examples of the ast please look at the [test files](https://go.dev/src/go/ast/example_test.go).

While building this, I was stuck at figuring out how to parse the file properly. Writing a python script would mean re-implementing the whole parser for struct. So golang's ast library was the best possible way.

That lead me to looking into the source code for [stringer](https://github.com/golang/tools/blob/master/cmd/stringer/stringer.go#L216) which automatically also solved my other problem of figuring out where to save the files and how to load them properly without having to deal with relative import paths. They are the worst.

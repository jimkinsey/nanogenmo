It is a truth universally acknowledged that a node js script begins with require statements:

    request = require 'request'
    qItUp = require 'q-it-up'
    q = require 'q'
    trampoline = require './trampoline'
    cheerio = require 'cheerio'
    underscore = require 'underscore'
    
The Request library is an HTTP wrapper that simplifies the making of HTTP requests. It will be required to get the content with which to build the novel. The Cheerio library is a JQuery-style HTML parser which will be used to extract data from the web-site. A trampoline function is useful for iterative asynchronous operations which terminate on a condition. Q-it-up is a library which makes it easy to translate a CPS-style function into one which instead returns a promise, useful for chaining asynchronous operations. Q is the promise library used by Q-it-up. Underscore provides a number of functional programming extensions to JavaScript.

Questions are gathered by performing a search, fetching the fulltext content for each item and extracting the questions until the number of words is above the required threshold.

A question is a string which, after trimming, ends with a question mark.

    isQuestion = (sentence) -> sentence.trim()[-1..] == '?'

Questions sometimes need 'cleaning up' as they contain trailing or leading whitespace or start with numbers from a section title.

    cleanUpQuestion = (question) ->
      console.log 'Cleaning up questions...'
      question.trim()
      .replace /^\d\s+/, ''
      .replace /^\d+\.\d+\s+/, ''
      
    cleanUpQuestions = (questions) -> questions.map cleanUpQuestion

We first need the textual content of the full text body (without tags). We then need to split the content into sentences. In this case we will use a regular expression which looks for strings ending in a full stop, question mark or exclamation mark followed by optional whitespace and a character which may start a sentence. This is used to insert a marker into the text which is then split on this marker.
 
    getSentences = (page) ->
      fulltext = cheerio.load(page)('div.FulltextWrapper').first()
      if fulltext?
        text = fulltext.text()
        text.replace(/([\.\?\!])(?!\d)|([^\d])\.(?=\d)/g,'$1$2|').split '|'
      else
        []

Getting the questions for a fulltext page will involve requesting the page then extracting the textual content and splitting it up into sentences, then filtering down to those which look like questions. This will be an asynchronous operation that returns a promise.

    getQuestionsFromSearchResults = (uris) ->
      console.log "Getting questions from #{uris.length} search results..."
      getQuestionsFromFulltextPage = (uri) ->
        deferred = q.defer()
        console.log "Getting questions from page at #{uri}"
        request.get uri, (err, res) ->
          if err? then deferred.reject err
          else
            deferred.resolve getSentences(res.body).filter(isQuestion)
        deferred.promise
      q.all(uris.map(getQuestionsFromFulltextPage))
      .then (setsOfQuestions) -> 
        underscore.flatten setsOfQuestions
      .fail console.error

Extracting the search results from the fulltext will involve finding the search result HTML elements using the appropriate CSS selector and filtering to those which have full text available. This function will return a promise although it is not asyncronous for readability and chaining with later asynchronous operations.

    extractSearchResultsWithFulltext = qItUp (resultsPage, callback) ->
      console.log "Extracting search results from page..."
      $ = cheerio.load resultsPage
      results = $('#results-list li').filter (i, li) -> 
        $(li).find('a.fulltext').first()?
      uris = results.map (i, li) -> 
        "http://link.springer.com#{$(li).find('a.fulltext').first().attr('href')}"
      callback null, uris.get()

The function which gets questions for a search result page will also need to trampoline as it will in turn get the fulltext for each qualifying search result, which again is an asynchronous process.

    getQuestionsForPage = (acc, pageNumber, callback) ->
      console.log "Getting questions for search page #{pageNumber}"
      request.get "http://link.springer.com/search/page/#{pageNumber}?query=&facet-content-type=%22Chapter%22&showAll=false", (err, res) ->
        if err?
          callback err
        else
          extractSearchResultsWithFulltext res.body
          .then getQuestionsFromSearchResults
          .then (qs) -> callback null, acc.concat qs

As the search is paginated and HTTP requests are asynchronous but we wish to stop once a condition is met, a trampoline function will be used which continues to perform the asynchronous request function until the termination condition is met. The asynchronus function will return a promise as this aids readability by reducing nesting of callback functions.

    gatherQuestions = (minWords) ->
      console.log "Gathering questions for min words #{minWords}"
      qItUp(trampoline)
        args: [ [], 1 ]
        fn: getQuestionsForPage
        done: (questions) -> wordsIn(questions).length >= minWords

To meet our condition for question gathering we need to count the words in our list of sentences. To do this, we count the words in each question and sum the result. A question may be split into words using the word boundary regex, the result of which needs to be filtered to remove the spaces between words and any punctuation.

    wordsIn = (sentences) ->
      underscore.flatten sentences.map (sentence) -> sentence.split(/\b/).filter (word) -> not(word.match(/(\s+|[\.\?\!\,\;\:])/)?)

Questions are marshalled into paragraphs algorithmically to produce a variety of paragraph structures. This works by chunking the array of questions into randomly sized sets before imposing a structure on each set.

Chunking the array is achieved recursively by taking a chunk, pushing it on to an array then concatenating the result of chunking the rest of the array. The chunk size is passed as a function so that it can vary betwen chunks.

    chunk = (array, chunkSize) ->
      if array.length == 0 then [] else chunked = [ array[0..chunkSize()] ].concat chunk array[chunkSize()-1..], chunkSize

    buildParagraphs = (questions) ->
      console.log 'Building paragraphs...'
      chunk(questions, -> Math.ceil Math.random() * 10)
      .map (questions) -> questions.join ' '
      

The algorithm will work by fetching content from the SpringerLink web-site and extracting questions, then going through a process of editing them into some kind of order and finally producing a conveniently readable output.

    gatherQuestions(minWords = 500)
    .then (questions) -> console.log "Got #{questions.length} questions"; questions
    .then cleanUpQuestions
    .then buildParagraphs
    .then (paras) -> paras.forEach console.log
    .fail console.warn


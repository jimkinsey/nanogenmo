It is a truth universally acknowledged that a node js script begins with require statements:

    request = require 'request'
    qItUp = require 'q-it-up'
    q = require 'q'
    trampoline = require './trampoline'
    cheerio = require 'cheerio'
    underscore = require 'underscore'
    PDFDocument = require 'pdfkit'
    fs = require 'fs'
    
The Request library is an HTTP wrapper that simplifies the making of HTTP requests. It will be required to get the content with which to build the novel. The Cheerio library is a JQuery-style HTML parser which will be used to extract data from the web-site. A trampoline function is useful for iterative asynchronous operations which terminate on a condition. Q-it-up is a library which makes it easy to translate a CPS-style function into one which instead returns a promise, useful for chaining asynchronous operations. Q is the promise library used by Q-it-up. Underscore provides a number of functional programming extensions to JavaScript. PDFKit is used to generate PDFs. Duh. fs is the standard node file-system module which will be required for saving the PDF.

Questions are gathered by performing a search, fetching the fulltext content for each item and extracting the questions until the number of words is above the required threshold.

A question is a string which, after trimming, ends with a question mark.

    isQuestion = (sentence) -> sentence.trim()[-1..] == '?'

Questions sometimes need 'cleaning up' as they contain trailing or leading whitespace or start with numbers from a section title.

    cleanUpQuestion = (question) ->
      question.trim()
      .replace /\s+/g, ' ' # collapse whitespace
      .replace /^\((.*)\)\s*$/, '$1' # de-bracket
      .replace /^\s*\)\s*/, '' # oddly hanging close brackets
      .replace /^\d\s+/, '' # section title prefixes e.g. 2
      .replace /^\d+\.\d+\s+/, '' # section title prefixes e.g. 1.3 
      .replace /^\d+\.\d+\.\d+\s*/, '' # section title prefixes e.g. 1.3.1 
      # .replace /\((\w+\s\d+\;*\s*)+\)/, '' # references e.g. (Minsky 1967), (Jones 2011; Smith 2000)
      .replace /^.*\d+\.\d+\s+/, '' # e.g. Grasping the challenges § 3.1 
      .replace /^[A-Za-z0-9\.\(]+\)/, '' # 'list' items starting i), ii), a), (A), 3.1) etc. ...
      .replace /^[:;]\s*/, '' # leading colons and semi-colons, side-effect of sentence-splitting
      
Some questions should be excluded from the list completely as they cannot be cleaned up due to the presence of special characters or other substrings which make the questions unintelligible or unsuitable for publication.

    countOf = (string, char) ->
      count = 0
      for c in string
        if c == char then count = count + 1
      count

    containsUnusableCharacters = (question) -> question.indexOf('©') > -1 
    containsDOI = (question) -> question.match(/10\.\d+\/.+\b/g)?
    containsUnbalancedQuotes = (question) -> countOf(question, '"') % 2 != 0
    containsNoAlphabeticCharacters = (question) -> not question.match(/[a-zA-Z"']/g)?
    endsWithInappropriateCharacter = (question) -> question.match(/[\\\(]\?$/)?
    isBlacklisted = (question) -> [ 'ro/?', 'cfm?', 'ro/​shop/​?' ].filter((bl) -> question.trim() == bl).length > 0
    looksLikeCrossRef = (question) -> question.indexOf('CrossRef') > -1
    looksLikePubMed = (question) -> question.indexOf('PubMed') > -1
    looksLikeSqlClause = (question) -> question.trim().match(/OR\s+[A-Za-z0-9]+=/g)?
    looksLikeUrlPath = (question) -> (question.indexOf('/') > -1) and (question.indexOf(' ') < 0)#question.match(/^[\/A-Za-z0-9_]+\?$/)?
    probablyContainsLaTeX = (question) -> question.match(/\\[a-z]+/)
    startsWithInappropriateCharacter = (question) -> not question.trim().match(/^[A-Za-z0-9]/)?

    isUsableQuestion = (question) ->
      underscore.every [
        containsUnusableCharacters,
        containsDOI,
        containsUnbalancedQuotes,
        containsNoAlphabeticCharacters,
        startsWithInappropriateCharacter,
        endsWithInappropriateCharacter,
        isBlacklisted,
        looksLikeCrossRef,
        looksLikePubMed,
        looksLikeSqlClause,
        looksLikeUrlPath,
        probablyContainsLaTeX
      ], (unusable) -> 
        usable = not unusable question
        unless usable then console.log "Question '#{question}' is not usable..."
        usable
      
    cleanUpQuestions = (questions) -> 
      questions
      .map cleanUpQuestion
      .filter isUsableQuestion

The questions will be rearranged to reduce repetitious passages, initially by shuffling them.

    rearrangeQuestions = (questions) -> underscore.shuffle questions

All good novels need a great first line, so this attempts to select one from the questions available by successive filtering to see how specifically criteria can be matched and then choosing the longest.

    successiveFilter = (array, preds) ->
      if preds.length == 0 then array
      else
        filtered = successiveFilter array.filter(preds[0]), preds[1..]
        if filtered.length == 0 then array
        else filtered

    getShortest = (strings) ->
      underscore.first underscore.sortBy strings, (s) -> s.length

    setUpKillerFirstLine = (questions) ->
      line = getShortest successiveFilter questions, [
        (question) -> question.toLowerCase().indexOf('this') > -1
        (question) -> question.toLowerCase().indexOf('novel') > -1 or question.toLowerCase().indexOf('work') > -1
      ]
      [ line ].concat questions # FIXME remove from questions

Similarly, we need a great last line, and one of the iterations of this programme accidentally threw up a good one, so this is an attempt to prefer that while maintaining the possibility of finding a differently interesting candidate:

    setUpKillerLastLine = (questions) ->
      line = getShortest successiveFilter questions, [
        (question) -> question.toLowerCase().indexOf('artificial intelligence') > -1 and question.toLowerCase().indexOf('insane') > -1
      ]
      questions.concat [ line ] # FIXME remove from questions

We first need the textual content of the full text body (without tags), which is wrapped in an element with the CSS class 'Fulltext'. There are descendant elements of this tag which contain inappropriate content, for example Tables and Figures, which should be removed before attempting to extract sentences.
 
    removeUnusableElements = ($) ->
      [ 
        '.Figure', 
        '.Table', 
        '.Bibliography', 
        '.Appendix', 
        '.Acknowledgments',
        '.Heading'
      ].forEach (sel) -> 
        $.find(sel).remove()

We then need to split the content into sentences. In this case we will use a regular expression which looks for strings ending in a full stop, question mark or exclamation mark followed by optional whitespace and a character which may start a sentence. This is used to insert a marker into the text which is then split on this marker.
  
    getSentences = (page) ->
      fulltext = cheerio.load(page)('div.Fulltext').first()
      if fulltext?
        removeUnusableElements fulltext
        text = fulltext.text()
        text.replace(/([\.\?\!])(?!\d)|([^\d])\.(?=\d)/g,'$1$2|').split '|'
      else
        []

Getting the questions for a fulltext page will involve requesting the page then extracting the textual content and splitting it up into sentences, then filtering down to those which look like questions. This will be an asynchronous operation that returns a promise.

    getQuestionsFromSearchResults = (uris) ->
      console.log "Getting questions from #{uris.length} search results..."
      getQuestionsFromFulltextPage = (uri) -> 
        console.log "Getting questions from #{uri}"
        qItUp(request.get)(uri).then ([response, body]) ->
          getSentences(body).filter(isQuestion)
      q.all(uris.map(getQuestionsFromFulltextPage))
      .then (setsOfQuestions) ->
        underscore.flatten setsOfQuestions
      .then cleanUpQuestions
      .fail console.error

Extracting the search results from the fulltext will involve finding the search result HTML elements using the appropriate CSS selector and filtering to those which have full text available. This function will return a promise although it is not asyncronous for readability and chaining with later asynchronous operations.

    extractSearchResultsWithFulltext = qItUp (resultsPage, callback) ->
      console.log "Extracting search results from page..."
      $ = cheerio.load resultsPage
      results = $('#results-list li').filter (i, li) -> 
        $(li).find('a.fulltext').first()?
      uris = results.map (i, li) -> 
        "http://link.springer.com#{$(li).find('a.fulltext').first().attr('href')}"
      callback null, uris.get().filter (uri) -> uri.indexOf('undefined') < 0

The function which gets questions for a search result page will also need to trampoline as it will in turn get the fulltext for each qualifying search result, which again is an asynchronous process. It will also deduplicate questions in advance of the count which terminates the trampoline, so that enough questions are gathered.

    #http://link.springer.com/search?query=Astronomy+OR+Psychiatry+OR+Philosophy+OR+Education+OR+Ancient+Greece+OR+Odysseus+OR+Ethics+OR+Artificial+Intelligence+OR+marriage+OR+semiotics&sortOrder=newestFirst&facet-content-type=%22Chapter%22
    
    getQuestionsForPage = (acc, pageNumber, callback) ->
      console.log "Getting questions for search page #{pageNumber}"
      request.get "http://link.springer.com/search/page/#{pageNumber}?query=&facet-content-type=%22Chapter%22&showAll=false", (err, res) ->
        if err?
          callback err
        else
          extractSearchResultsWithFulltext res.body
          .then getQuestionsFromSearchResults
          .then (qs) -> callback null, underscore.uniq(acc.concat(qs)), pageNumber + 1

As the search is paginated and HTTP requests are asynchronous but we wish to stop once a condition is met, a trampoline function will be used which continues to perform the asynchronous request function until the termination condition is met. The asynchronus function will return a promise as this aids readability by reducing nesting of callback functions.

    gatherQuestions = (minWords) ->
      console.log "Gathering questions for min words #{minWords}"
      qItUp(trampoline)
        args: [ [], 1 ]
        fn: getQuestionsForPage
        done: (questions, pageNumber) -> wordsIn(questions).length >= minWords
      .then ([questions, pageNumber]) -> questions

To meet our condition for question gathering we need to count the words in our list of sentences. To do this, we count the words in each question and sum the result. A question may be split into words using the word boundary regex, the result of which needs to be filtered to remove the spaces between words and any punctuation.

    wordsIn = (sentences) ->
      underscore.flatten sentences.map (sentence) -> sentence.split(/\b/).filter (word) -> not(word.match(/(\s+|[\.\?\!\,\;\:])/)?)

Questions are marshalled into paragraphs algorithmically to produce a variety of paragraph structures. This works by chunking the array of questions into randomly sized sets before imposing a structure on each set. The final paragraph should be just one line.

Chunking the array is achieved recursively by taking a chunk, pushing it on to an array then concatenating the result of chunking the rest of the array. The chunk size is passed as a function so that it can vary betwen chunks.

    chunk = (array, size) ->
      if array.length == 0 then [] else 
        chunkSize = size()
        [ array[0..chunkSize-1] ].concat chunk array[chunkSize..], size
      
    buildParagraphs = (questions) ->
      console.log 'Building paragraphs...'
      chunk(questions[0...-1], -> Math.ceil Math.random() * 7)
      .map (qs) -> qs.join ' '
      .concat questions[-1..]
      
Paragraphs are gathered into chapters in a similar way by random chunking, but with a tighter range of chunk sizes with a higher minimum value as a one paragraph chapter would stand out a bit sharply.

    buildChapters = (paragraphs) ->
      console.log 'Building chapters...'
      chunk(paragraphs, -> 20 + Math.floor Math.random() * 10)
      .map (paragraphs) -> paragraphs.join '\n\t'

The final typesetting of the book is performed by streaming the chapters out to a PDF file with a page break and chapter title between each. The PDF file will have a title page with the title of the novel and some descriptive text indicating its origin.

The name of the file will be based on the current draft number to maintain a history of drafts, based on whether a file exists with the current draft number.

    nextDraftName = (number = 1) ->
      unless fs.existsSync "draft-#{number}.pdf" then "draft-#{number}.pdf" else nextDraftName number + 1
      
    typesetBook = (chapters) ->
      console.log "Typesetting book..."
      doc = new PDFDocument
      filename = nextDraftName()
      doc.pipe fs.createWriteStream filename
      doc.font '/Library/Fonts/Marion.ttc', 'Marion-Bold'
      doc.fontSize 36
      doc.text 'Springer Link: A Novel?\n\n'
      doc.font '/Library/Fonts/Marion.ttc', 'Marion-Regular'
      doc.fontSize 14
      doc.text "A #NaNoGenMo 2014 entry using content from Springer-Link (http://link.springer.com), inspired by Padget Powell's 'The Interrogative Mood: A Novel?', devised and engineered by Jim Kinsey on a Springer hack day."
      doc.addPage()
      underscore.zip([1..chapters.length], chapters).forEach ([number, chapter]) ->
        doc.font '/Library/Fonts/Marion.ttc', 'Marion-Bold'
        doc.fontSize 20
        doc.text "Chapter #{number}\n\n"
        doc.font '/Library/Fonts/Marion.ttc', 'Marion-Regular'
        doc.fontSize 14
        doc.text chapter
        doc.addPage()
      doc.end() 
      console.log "Wrote file '#{filename}"

The algorithm will work by fetching content from the SpringerLink web-site and extracting questions, then going through a process of editing them into some kind of order and finally producing a conveniently readable output.

    gatherQuestions(minWords = 500)
    .then rearrangeQuestions
    .then setUpKillerFirstLine
    .then setUpKillerLastLine
    .then buildParagraphs
    .then buildChapters
    .then typesetBook
    .fail (err) -> console.error "ERROR: #{err} #{err.stack}"
    .fin

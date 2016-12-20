d3 = require 'd3'
debounce = require 'debounce'
{ split, intersects, distance, merged, after, subtract } = require './utils.coffee'

class TimeSlider

    # TODO: Not sure if this is the only solution but this is needed to make sure
    #       events can be dispatched in Internet Explorer 11 (and below)
    `(function () {
      function CustomEvent ( event, params ) {
        params = params || { bubbles: false, cancelable: false, detail: undefined };
        var evt = document.createEvent( 'CustomEvent' );
        evt.initCustomEvent( event, params.bubbles, params.cancelable, params.detail );
        return evt;
       }

      CustomEvent.prototype = window.Event.prototype;

      window.CustomEvent = CustomEvent;
    })();`


    # TODO
    #  * Implement a function to fetch dataset information from a WMS / WCS service
    #  * Compute the padding at the left & right of the timeslider
    #  * TESTING

    constructor: (@element, @options = {}) ->
        @brushTooltip = @options.brushTooltip
        @brushTooltipOffset = [30, 20]

        @tooltip = d3.select(@element).append("div")
            .attr("class", "timeslider-tooltip")
            .style("opacity", 0)

        @tooltipBrushMin = d3.select(@element).append("div")
            .attr("class", "timeslider-tooltip")
            .style("opacity", 0)
        @tooltipBrushMax = d3.select(@element).append("div")
            .attr("class", "timeslider-tooltip")
            .style("opacity", 0)

        @tooltipFormatter = @options.tooltipFormatter || (record) -> record[2]?.id || record[2]?.name
        @binTooltipFormatter = @options.binTooltipFormatter || (bin) =>
            bin.map(@tooltipFormatter)
                .filter((tooltip) -> tooltip?)
                .join("<br>")

        # used for show()/hide()
        @originalDisplay = @element.style.display

        # create the root svg element
        @svg = d3.select(@element).append('svg')
            .attr('class', 'timeslider')


        # TODO: what does this do???

        @useBBox = false
        if @svg[0][0].clientWidth == 0
            d3.select(@element).select('svg')
                .append('rect').attr('width', '100%')
                .attr('height', '100%')
                .attr('opacity', '0')
            @useBBox = true

        # default options and other variables for later
        if @useBBox
            @options.width = @svg[0][0].getBBox().width
            @options.height = @svg[0][0].getBBox().height
        else
            @options.width = @svg[0][0].clientWidth
            @options.height = @svg[0][0].clientHeight

        @options.selectionLimit = if @options.selectionLimit then parseDuration(@options.selectionLimit) else null

        @options.brush ||= {}
        @options.brush.start ||= @options.start
        if @options.selectionLimit
            @options.brush.end ||= offsetDate(@options.brush.start, @options.selectionLimit)
        else
            @options.brush.end ||= new Date(new Date(@options.brush.start).setDate(@options.brush.start.getDate() + 3))

        @selectionConstraint = [
            offsetDate(@options.brush.start, -@options.selectionLimit),
            offsetDate(@options.brush.end, @options.selectionLimit)
        ]

        domain = @options.domain

        @options.displayLimit = if @options.displayLimit then parseDuration(@options.displayLimit) else null
        @options.display ||= {}
        if not @options.display.start and @options.displayLimit
            @options.display.start = offsetDate(domain.end, -@options.displayLimit)
        else
            @options.display.start ||= domain.start
        @options.display.end ||= domain.end

        if @options.displayLimit != null and (@options.display.end - @options.display.start) > @options.displayLimit * 1000
            @options.display.start = offsetDate(@options.display.end, -@options.displayLimit)

        @options.debounce ||= 50
        @options.ticksize ||= 3
        @options.datasets ||= []

        @recordFilter = @options.recordFilter

        # object to hold individual data points / data ranges
        @datasets = {}
        @ordinal = 0

        @simplifyDate = d3.time.format.utc("%d.%m.%Y - %H:%M:%S")

        customFormats = d3.time.format.utc.multi([
            [".%L", (d) -> d.getUTCMilliseconds() ]
            [":%S", (d) -> d.getUTCSeconds() ],
            ["%H:%M", (d) -> d.getUTCMinutes() ],
            ["%H:%M", (d) -> d.getUTCHours() ],
            ["%b %d %Y ", (d) ->d.getUTCDay() && d.getUTCDate() != 1 ],
            ["%b %d %Y", (d) -> d.getUTCDate() != 1 ],
            ["%B %Y", (d) -> d.getUTCMonth() ],
            ["%Y", -> true ]
        ])

        # scales
        @scales = {
            x: d3.time.scale.utc()
                .domain([ @options.display.start, @options.display.end ])
                .range([0, @options.width])
            y: d3.scale.linear()
                .range([@options.height-29, 0])
        }

        # axis
        @axis = {
            x: d3.svg.axis()
                .scale(@scales.x)
                .innerTickSize(@options.height - 15)
                .tickFormat(customFormats)
            y: d3.svg.axis()
                .scale(@scales.y)
                .orient("left")
        }

        @svg.append('g')
            .attr('class', 'mainaxis')
            .call(@axis.x)

        # translate the main x axis
        d3.select(@element).select('g.mainaxis .domain')
            .attr('transform', "translate(0, #{@options.height - 18})")

        @setBrushTooltip = (active) =>
            @brushTooltip = active

        @setBrushTooltipOffset = (offset) =>
            @brushTooltipOffset = offset

        # create the brush with all necessary event callbacks
        @brush = d3.svg.brush()
            .x(@scales.x)
            .on('brushstart', =>
                # deactivate zoom behavior
                @brushing = true
                @prevTranslate = @options.zoom.translate()
                @prevScale = @options.zoom.scale()
                @selectionConstraint = null

                # show the brush tooltips
                if @brushTooltip
                    @tooltipBrushMin.transition()
                        .duration(100)
                        .style("opacity", .9)
                    @tooltipBrushMax.transition()
                        .duration(100)
                        .style("opacity", .9)
            )
            .on('brushend', =>
                @brushing = false
                @options.zoom.translate(@prevTranslate)
                @options.zoom.scale(@prevScale)

                @checkBrush()
                @redraw()

                @selectionConstraint = null

                # dispatch the events
                @dispatch('selectionChanged', {
                    start: @brush.extent()[0],
                    end: @brush.extent()[1]
                })

                # hide the brush tooltips
                if @brushTooltip
                    @tooltipBrushMin.transition()
                        .duration(100)
                        .style("opacity", 0)
                    @tooltipBrushMax.transition()
                        .duration(100)
                        .style("opacity", 0)

                @wasBrushing = true
            )
            .on('brush', =>
                if @options.selectionLimit != null
                    if @selectionConstraint == null
                        [low, high] = @brush.extent()
                        @selectionConstraint = [
                            offsetDate(high, - @options.selectionLimit),
                            offsetDate(low, @options.selectionLimit)
                        ]
                    else
                        if d3.event.mode == "move"
                            [low, high] = @brush.extent()
                            @selectionConstraint = [
                                offsetDate(high, - @options.selectionLimit),
                                offsetDate(low, @options.selectionLimit)
                            ]
                        @checkBrush()

                @redraw()
            )
            .extent([@options.brush.start, @options.brush.end])

        # add a group to draw the brush in
        @svg.append('g')
            .attr('class', 'brush')
            .call(@brush)
            .selectAll('rect')
                .attr('height', "#{@options.height - 19}")
                .attr('y', 0)

        # add a group that contains all datasets
        @svg.append('g')
            .attr('class', 'datasets')
            .attr('width', @options.width)
            .attr('height', @options.height)
            .attr('transform', "translate(0, #{@options.height - 23})")

        # handle window resizes
        d3.select(window)
            .on('resize', =>
                # update the width of the element and the scales
                svg = d3.select(@element).select('svg.timeslider')[0][0]
                @options.width = if @useBBox then svg.getBBox().width else svg.clientWidth
                @scales.x.range([0, @options.width])

                @redraw()
            )

        # create the zoom behavior
        minScale = (@options.display.start - @options.display.end) / (@options.domain.start - @options.domain.end)

        @options.zoom = d3.behavior.zoom()
            .x(@scales.x)
            .size([@options.width, @options.height])
            .scaleExtent([minScale, Infinity])
            .on('zoomstart', =>
                @prevScale2 = @options.zoom.scale()
                @prevDomain = @scales.x.domain()
            )
            .on('zoom', =>
                if @brushing
                    @options.zoom.scale(@prevScale)
                    @options.zoom.translate(@prevTranslate)
                else
                    if @options.displayLimit != null and d3.event.scale < @prevScale2
                        [low, high] = @scales.x.domain()

                        if (high.getTime() - low.getTime()) > @options.displayLimit * 1000
                            [start, end] = @prevDomain
                        else
                            [start, end] = @scales.x.domain()

                    else
                        [start, end] = @scales.x.domain()

                    @center(start, end, false)
                    @prevScale2 = @options.zoom.scale()
                    @prevDomain = @scales.x.domain()
            )
            .on('zoomend', =>
                display = @scales.x.domain()
                @dispatch('displayChanged', {
                    start: display[0],
                    end: display[1]
                })
                if not @wasBrushing
                    for dataset of @datasets
                        @reloadDataset(dataset)
                @wasBrushing = false
            )
        @svg.call(@options.zoom)

        # initialize all datasets
        for definition in @options.datasets
            do (definition) => @addDataset(definition)

        # show the initial time span
        if @options.display
            @center(@options.display.start, @options.display.end)

    ###
    ## Private API
    ###

    checkBrush: ->
        if @selectionConstraint
            [a, b] = @selectionConstraint
            [x, y] = @brush.extent()

            if x < a
                x = a
            if y > b
                y = b

            @brush.extent([x, y])

    redraw: ->
        # update brush
        @brush.x(@scales.x).extent(@brush.extent())

        # repaint the axis and the brush
        d3.select(@element).select('g.mainaxis').call(@axis.x)
        d3.select(@element).select('g.brush').call(@brush)

        # redraw brushes
        if @brushTooltip
            offheight = 0
            if @svg[0][0].parentElement?
                offheight = @svg[0][0].parentElement.offsetHeight
            else
                offheight = @svg[0][0].parentNode.offsetHeight

            @tooltipBrushMin.html(@simplifyDate(@brush.extent()[0]))
            @tooltipBrushMax.html(@simplifyDate(@brush.extent()[1]))

            centerTooltipOn(@tooltipBrushMin, d3.select(@element).select('g.brush .extent')[0][0], 'left', [0, -20])
            centerTooltipOn(@tooltipBrushMax, d3.select(@element).select('g.brush .extent')[0][0], 'right')

        brushExtent = d3.select(@element).select('g.brush .extent')
        if parseFloat(brushExtent.attr('width')) < 1
            brushExtent.attr('width', 1)


        # repaint the datasets
        # First paint lines and ticks
        for dataset of @datasets
            if !@datasets[dataset].lineplot
                @redrawDataset(dataset)

        # Afterwards paint lines so they are not overlapped
        for dataset of @datasets
            if @datasets[dataset].lineplot
                @redrawDataset(dataset)

        # add classes to the ticks. When we are dealing with dates
        # (i.e: ms, s, m and h are zero), add the tick-date class
        d3.select(@element).selectAll('.mainaxis g.tick text')
          .classed('tick-date', (d) -> !(
            d.getUTCMilliseconds() | d.getUTCSeconds() | d.getUTCMinutes() | d.getUTCHours()
          ))

    # Convenience method to hook up a single record elements events
    setupRecord: (recordElement, dataset) ->
        recordElement.attr('fill', (record) =>
            if not @recordFilter or @recordFilter(record, dataset)
                dataset.color
            else
                "transparent"
        )
        .on('mouseover', (record) =>
            if record.cluster
                @dispatch('clusterMouseover', {
                    dataset: dataset.id,
                    start: record[0],
                    end: record[1],
                    records: record[2]
                })
                tooltip = @binTooltipFormatter(record[2], dataset)
            else
                @dispatch('recordMouseover', {
                    dataset: dataset.id,
                    start: record[0],
                    end: record[1],
                    params: record[2]
                })
                tooltip = @tooltipFormatter(record, dataset)

            if tooltip
                @tooltip.html(tooltip)
                    .transition()
                    .duration(200)
                    .style("opacity", .9)
                centerTooltipOn(@tooltip, d3.event.target)
        )
        .on('mouseout', (record) =>
            if record.cluster
                @dispatch('clusterMouseout', {
                    dataset: dataset.id,
                    start: record[0],
                    end: record[1],
                    records: record[2]
                })
            else
                @dispatch('recordMouseout', {
                    dataset: dataset.id,
                    start: record[0],
                    end: record[1],
                    params: record[2]
                })
            @tooltip.transition()
                .duration(500)
                .style("opacity", 0)
        )
        .on('click', (record) =>
            if record.cluster
                @dispatch('clusterClicked', {
                    dataset: dataset.id,
                    start: record[0],
                    end: record[1],
                    records: record[2]
                })
            else
                @dispatch('recordClicked', {
                    dataset: dataset.id,
                    start: record[0],
                    end: record[1],
                    params: record[2]
                })
        )

    setupBin: (binElement, dataset, y) ->
        binElement
            .attr("class", "bin")
            .attr("fill", dataset.color)
            .attr("x", 1)
            .attr("width", (d) => @scales.x(d.x.getTime() + d.dx) - @scales.x(d.x) - 1)
            .attr("transform", (d) => "translate(" + @scales.x(new Date(d.x)) + ",-" + y(d.length) + ")")
            .attr("height", (d) -> y(d.length))

        binElement
        .on("mouseover", (bin) =>
            @dispatch('binMouseover', {
                dataset: dataset.id,
                start: bin.x,
                end: new Date(bin.x.getTime() + bin.dx),
                bin: bin
            })

            if bin.length
                tooltip = @binTooltipFormatter(bin)
                if tooltip.length
                    @tooltip.html(tooltip)
                        .transition()
                        .duration(200)
                        .style("opacity", .9)
                    centerTooltipOn(@tooltip, d3.event.target)
        )
        .on("mouseout", (bin) =>
            @dispatch('binMouseout', {
                dataset: dataset.id,
                start: bin.x,
                end: new Date(bin.x.getTime() + bin.dx),
                bin: bin
            })
            @tooltip.transition()
                .duration(500)
                .style("opacity", 0)
        )
        .on('click', (bin) =>
            @dispatch('binClicked', {
                dataset: dataset.id,
                start: bin.x,
                end: new Date(bin.x.getTime() + bin.dx),
                bin: bin
            })
        )

    drawRanges: (datasetElement, dataset, records) ->
        rect = (elem) =>
            elem.attr('class', 'record')
                .attr('x', (record) => @scales.x(new Date(record[0])) )
                .attr('y', - (@options.ticksize + 3) * dataset.index + -(@options.ticksize-2) )
                .attr('width', (record) => @scales.x(new Date(record[1])) - @scales.x(new Date(record[0])) )
                .attr('height', (@options.ticksize-2))
                .attr('stroke', d3.rgb(dataset.color).darker())
                .attr('stroke-width', 1)

        r = datasetElement.selectAll('rect.record')
            .data(records)
            .call(rect)

        r.enter().append('rect')
            .call(rect)
            .call((recordElement) => @setupRecord(recordElement, dataset))

        r.exit().remove()

    drawPoints: (datasetElement, dataset, records) ->
        circle = (elem) =>
            elem.attr('class', 'record')
                .attr('cx', (a) =>
                    if Array.isArray(a)
                        if a[0] != a[1]
                            return @scales.x(new Date(a[0].getTime() + Math.abs(a[1] - a[0]) / 2))
                        return @scales.x(new Date(a[0]))
                    else
                        return @scales.x(new Date(a))
                )
                .attr('cy', - (@options.ticksize + 3) * dataset.index - (@options.ticksize - 2) / 2)
                .attr('stroke', d3.rgb(dataset.color).darker())
                .attr('stroke-width', 1)
                .attr('r', @options.ticksize / 2)

        p = datasetElement.selectAll('circle.record')
            .data(records)
            .call(circle)

        p.enter().append('circle')
            .call(circle)
            .call((recordElement) => @setupRecord(recordElement, dataset))

        p.exit().remove()

    drawHistogram: (datasetElement, dataset, records) ->
        ticks = @scales.x.ticks(dataset.histogramBinCount or 20)
        dx = ticks[1] - ticks[0]
        ticks = [new Date(ticks[0].getTime() - dx)].concat(ticks).concat([new Date(ticks[ticks.length - 1].getTime() + dx)])

        bins = d3.layout.histogram()
          .bins(ticks)
          .range(@scales.x.domain())
          .value((record) -> new Date(record[0] + (record[1] - record[0]) / 2))(records)
          .filter((b) -> b.length)

        y = d3.scale.linear()
          .domain([0, d3.max(bins, (d) -> d.length)])
          .range([2, @options.height - 29])
          .clamp(true)

        bars = datasetElement.selectAll(".bin")
          .data(bins)

        bars.attr("class", "bin")
          .call((binElement) => @setupBin(binElement, dataset, y))

        bars.enter().append("rect")
          .call((binElement) => @setupBin(binElement, dataset, y))

        bars.exit().remove()

    drawPaths: (datasetElement, dataset, data) ->
        @scales.y.domain(d3.extent(data, (d) -> d[1]))

        datasetElement.selectAll('path').remove()
        datasetElement.selectAll('.y.axis').remove()

        line = d3.svg.line()
            .x( (a) => @scales.x(new Date(a[0])) )
            .y( (a) => @scales.y(a[1]) )

        # TODO: Tests with clipping mask for better readability
        # element.attr("clip-path", "url(#clip)")

        # clippath = element.append("defs").append("svg:clipPath")
        #     .attr("id", "clip")

        # element.select("#clip").append("svg:rect")
        #         .attr("id", "clip-rect")
        #         .attr("x", (options.index+1)*30)
        #         .attr("y", -@options.height)
        #         .attr("width", 100)
        #         .attr("height", 100)

        datasetElement.append("path")
            #.attr("clip-path", "url(#clip)")
            .datum(data)
            .attr("class", "line")
            .attr("d", line)
            .attr('stroke', dataset.color)
            .attr('stroke-width', "1.5px")
            .attr('fill', 'none')
            .attr('transform', "translate(0,"+ (-@options.height+29)+")")


        step = (@scales.y.domain()[1] - @scales.y.domain()[0])/4
        @axis.y.tickValues(
            d3.range(@scales.y.domain()[0], @scales.y.domain()[1]+step, step)
        )

        datasetElement.append("g")
            .attr("class", "y axis")
            .attr('fill', dataset.color)
            .call(@axis.y)
            .attr("transform", "translate("+((dataset.index+1)*30)+","+ (-@options.height+29)+")")

        datasetElement.selectAll('.axis .domain')
            .attr("stroke-width", "1")
            .attr("stroke", dataset.color)
            .attr("shape-rendering", "crispEdges")
            .attr("fill", "none")

        datasetElement.selectAll('.axis line')
            .attr("stroke-width", "1")
            .attr("shape-rendering", "crispEdges")
            .attr("stroke", dataset.color)

        datasetElement.selectAll('.axis path')
            .attr("stroke-width", "1")
            .attr("shape-rendering", "crispEdges")
            .attr("stroke", dataset.color)

    # this function acually draws a dataset

    redrawDataset: (datasetId) ->
        dataset = @datasets[datasetId]
        if not dataset
            return

        [low, high] = @scales.x.domain()

        records = (dataset.getRecords() || [])
            .filter((r) -> r[0] <= high and r[1] >= low)
        paths = dataset.getPaths()
        index = dataset.index
        color = dataset.color

        if paths and paths.length
            @drawPaths(dataset.element, dataset, paths)
        else
            if dataset.histogramThreshold? and records.length >= dataset.histogramThreshold
                dataset.element.selectAll('.record').remove()
                data = records.map((record) =>
                    new Date(record[0] + (record[1] - record[0]) / 2)
                )
                @drawHistogram(dataset.element, dataset, records)
            else
                dataset.element.selectAll('.bin').remove()

                x = @scales.x

                drawAsPoint = (record, scale) ->
                    return (scale(record[1]) - scale(record[0])) < 5

                reducer = (acc, current, index) =>
                    if drawAsPoint(current, x)
                        [intersecting, nonIntersecting] = split(acc, (b) ->
                            distance(current, b, x) <= 5
                        )
                    else
                        [intersecting, nonIntersecting] = split(acc, (b) ->
                            intersects(current, b)
                        )
                    if intersecting.length
                        newBin = [
                          new Date(d3.min(intersecting, (b) -> b[0])),
                          new Date(d3.max(intersecting, (b) -> b[1])),
                          intersecting.map((b) -> b[2]).reduce(((a, r) -> a.concat(r)), [])
                        ]
                        newBin[0] = current[0] if current[0] < newBin[0]
                        newBin[1] = current[1] if current[1] > newBin[1]
                        newBin[2].push(current)
                        newBin.cluster = true
                        nonIntersecting.push(newBin)
                        return nonIntersecting
                    else
                        acc.push([current[0], current[1], [current]])
                    return acc

                if dataset.cluster
                    records = records
                        .reduce(reducer, [])
                        .map((r) -> if r.cluster then r else [r[0], r[1], r[2][0][2]])

                [points, ranges] = split(records, (r) -> drawAsPoint(r, x))

                @drawRanges(dataset.element, dataset, ranges)
                @drawPoints(dataset.element, dataset, points)

    # this function triggers the reloading of a dataset (sync)

    reloadDataset: (datasetId) ->
        dataset = @datasets[datasetId]
        [ start, end ] = @scales.x.domain()

        # start the dataset synchronization
        dataset.sync(start, end, (records, paths) =>
            finalRecords = []
            finalPaths = []

            if !dataset.lineplot
                for record in records
                    if record instanceof Date
                        record = [ record, record ]

                    else if not (record[1] instanceof Date)
                        record = [ record[0], record[0] ].concat(record[1..])

                    finalRecords.push(record)
            else
                # TODO: perform check of records
                finalPaths = records

            dataset.setRecords(finalRecords)
            dataset.setPaths(finalPaths)
            @redrawDataset(datasetId)
        )

    dispatch: (name, detail) ->
        @element.dispatchEvent(
            new CustomEvent(name, {
                detail: detail,
                bubbles: true,
                cancelable: true
            })
        )

    parseDuration = (duration) ->
        if not isNaN(parseFloat(duration))
            return parseFloat(duration)

        matches = duration.match(/^P(?:([0-9]+)Y|)?(?:([0-9]+)M|)?(?:([0-9]+)D|)?T?(?:([0-9]+)H|)?(?:([0-9]+)M|)?(?:([0-9]+)S|)?$/)

        if matches
            years = (parseInt(matches[1]) || 0) # years
            months = (parseInt(matches[2]) || 0) + years * 12 # months
            days = (parseInt(matches[3]) || 0) + months * 30 # days
            hours = (parseInt(matches[4]) || 0) + days * 24 # hours
            minutes = (parseInt(matches[5]) || 0) + hours * 60 # minutes
            return (parseInt(matches[6]) || 0) + minutes * 60 # seconds

    offsetDate = (date, seconds) ->
        return new Date(date.getTime() + seconds * 1000)

    centerTooltipOn = (tooltip, target, dir = 'center', offset = [0, 0]) ->
        rect = target.getBoundingClientRect()
        tooltipRect = tooltip[0][0].getBoundingClientRect()
        if dir == 'left'
            xOff = rect.left
        else if dir == 'right'
            xOff = rect.right
        else
            xOff = rect.left + rect.width / 2
        tooltip
            .style('left', xOff - tooltipRect.width / 2 + offset[0] + "px")
            .style('top', (rect.top - tooltipRect.height) + offset[1] + "px")

    ###
    ## Public API
    ###

    # convenience funtion to hide the TimeSlider
    hide: ->
        @element.style.display = 'none'
        true

    # convenience function to show a previously hidden TimeSlider
    show: ->
        @element.style.display = @originalDisplay
        true

    # set a new domain of the TimeSlider. redraws.
    domain: (params...) ->
        # TODO: more thorough input checking
        return false unless params.length == 2

        start = new Date(params[0])
        end = new Date(params[1])
        [ start, end ] = [ end, start ] if end < start

        @options.domain.start = start
        @options.domain.end = end

        @scales.x.domain([ @options.domain.start, @options.domain.end ])
        @redraw()

        true

    # select the specified time span
    select: (params...) ->
        return false unless params.length == 2

        start = new Date(params[0])
        end = new Date(params[1])
        [ start, end ] = [ end, start ] if end < start

        start = @options.start if start < @options.start
        end = @options.end if end > @options.end

        d3.select(@element).select('g.brush')
            .call(@brush.extent([start, end]))
        @element.dispatchEvent(new CustomEvent('selectionChanged', {
            detail: {
                start: @brush.extent()[0],
                end: @brush.extent()[1]
            }
            bubbles: true,
            cancelable: true
        }))
        true

    # add a dataset to the TimeSlider. redraws.
    # the dataset definition shall have the following values:
    #  *
    #
    addDataset: (definition) ->
        @options.datasetIndex = 0 unless @options.datasetIndex?
        @options.linegraphIndex = 0 unless @options.linegraphIndex?

        index = @options.datasetIndex
        lineplot = false

        id = definition.id
        @ordinal++

        if !definition.lineplot
            index = @options.datasetIndex++
            @svg.select('g.datasets')
                .insert('g',':first-child')
                    .attr('class', 'dataset')
                    .attr('id', "dataset-#{@ordinal}")
        else
            index = @options.linegraphIndex++
            lineplot = true
            @svg.select('g.datasets')
                .append('g')
                    .attr('class', 'dataset')
                    .attr('id', "dataset-#{@ordinal}")

        element = @svg.select("g.datasets #dataset-#{@ordinal}")

        @datasets[id] = new Dataset({
            id: id,
            index: index,
            color: definition.color,
            source: definition.source,
            records: definition.records,
            lineplot: lineplot,
            debounceTime: @options.debounce,
            ordinal: @ordinal,
            element: element,
            histogramThreshold: definition.histogramThreshold,
            histogramBinCount: definition.histogramBinCount,
            cacheRecords: definition.cacheRecords,
            cluster: definition.cluster
        })

        @reloadDataset(id)

    # remove a dataset. redraws.
    removeDataset: (id) ->
        return false unless @datasets[id]?

        dataset = @datasets[id]
        i = dataset.index
        lp = dataset.lineplot
        ordinal = dataset.ordinal
        delete @datasets[id]

        if lp
            @options.linegraphIndex--
        else
            @options.datasetIndex--

        d3.select(@element).select("g.dataset#dataset-#{ordinal}").remove()

        for dataset of @datasets
            if lp == @datasets[dataset].lineplot
                @datasets[dataset].index -= 1 if @datasets[dataset].index > i

        @redraw()
        true

    hasDataset: (id) ->
        return false unless @datasets[id]?

    # redraws.
    center: (start, end, doReload = true) ->
        start = new Date(start)
        end = new Date(end)
        [ start, end ] = [ end, start ] if end < start

        # constrain to domain, if set
        diff = end - start
        if @options.constrain && start < @options.domain.start
            start = @options.domain.start
            newEnd = new Date(start.getTime() + diff)
            end = if newEnd < @options.domain.end then newEnd else @options.domain.end
        if @options.constrain && end > @options.domain.end
            end = @options.domain.end
            newStart = new Date(end.getTime() - diff)
            start = if newStart > @options.domain.start then newStart else @options.domain.start

        # constrain to displayLimit
        if @options.displayLimit != null and (end - start) > @options.displayLimit * 1000
            start = offsetDate(end, -@options.displayLimit)

        @options.zoom.scale((@options.display.end - @options.display.start) / (end - start))
        @options.zoom.translate([ @options.zoom.translate()[0] - @scales.x(start), 0 ])
        @redraw()
        if doReload
            for dataset of @datasets
                @reloadDataset(dataset)
        true

    # zoom to start/end. redraws.
    zoom: (params...) ->
        start = new Date(params[0])
        end = new Date(params[1])
        [ start, end ] = [ end, start ] if end < start

        # constrain to domain, if set
        diff = end - start
        if @options.constrain && start < @options.domain.start
            start = @options.domain.start
            newEnd = new Date(start.getTime() + diff)
            end = if newEnd < @options.domain.end then newEnd else @options.domain.end
        if @options.constrain && end > @options.domain.end
            end = @options.domain.end
            newStart = new Date(end.getTime() - diff)
            start = if newStart > @options.domain.start then newStart else @options.domain.start

        # constrain to displayLimit
        if @options.displayLimit != null and (end - start) > @options.displayLimit * 1000
            start = offsetDate(end, -@options.displayLimit)

        d3.transition().duration(750).tween('zoom', =>
            iScale = d3.interpolate(@options.zoom.scale(),
                (@options.domain.end - @options.domain.start) / (end - start))
            return (t) =>
                iPan = d3.interpolate(@options.zoom.translate()[0], @options.zoom.translate()[0] - @scales.x(start))

                @options.zoom.scale(iScale(t))
                @options.zoom.translate([ (iPan(t)), 0 ])

                # redraw
                @redraw()
        )
        .each('end', => @reloadDataset(dataset) for dataset of @datasets)
        true

    # reset the zoom to the initial domain
    reset: ->
        @zoom(@options.domain.start, @options.domain.end)
        true

    # enable or disable the brush tooltip
    setBrushTooltip: (@brushTooltip) ->

    # set the offset of the brush tooltip
    setBrushTooltipOffset: (@brushTooltipOffset) ->

    # sets a new record filter. This shall be a a callable that shall handle a
    # single record. redraws.
    setRecordFilter: (@recordFilter) ->
        @redraw()
        true

    setTooltipFormatter: (@tooltipFormatter) ->

    setBinTooltipFormatter: (@binTooltipFormatter) ->


# cache for records and their respective intervals
class RecordCache
    constructor: (@idProperty) ->
        if @idProperty
            @predicate = (a, b) -> a[2][@idProperty] is b[2][@idProperty]
        else
            @predicate = (a, b) -> a[0] is b[0] and a[1] is b[1]
        @clear()

    # clear the cache
    clear: () ->
        @buckets = []

    # add the interval with records to the cache. this can trigger a merge with
    # buckets.
    add: (start, end, records) ->
        intersecting = @getIntersecting(start, end)
        notIntersecting = @buckets
            .filter(([startA, endA, ...]) -> not intersects([start, end], [startA, endA]))

        low = start
        high = end
        combined = records

        for [bucketStart, bucketEnd, bucketRecords] in intersecting
            low = bucketStart if bucketStart < low
            high = bucketEnd if bucketEnd > high
            combined = merged(combined, bucketRecords, @predicate)
        @buckets = notIntersecting
        @buckets.push([low, high, combined])

    # get the records for the given interval (can be of more than one bucket)
    get: (start, end) ->
        intersecting = @getIntersecting(start, end)
        if intersecting.length == 0
            return []

        [first, others...] = intersecting
        records = first[2]
        for intersection in others
            records = merged(records, intersection[2], @predicate)
        return records

    # fetch the source, but only the intervals that are required
    fetch: (start, end, params, source, callback) ->
        intersecting = @getIntersecting(start, end)
        intervals = [[start, end],]
        for bucket in intersecting
            newIntervals = []
            for interval in intervals
                newIntervals = newIntervals.concat(subtract(interval, bucket))
            intervals = newIntervals

        if intervals.length
            summaryCallback = after(intervals.length, () =>
                callback(@get(start, end))
            )

            for [intStart, intEnd] in intervals
                source(intStart, intEnd, params, (records, paths) =>
                    @add(intStart, intEnd, records)
                    summaryCallback()
                )
        else
            # fill entire answer from cache
            callback(@get(start, end))

    getIntersecting: (start, end) ->
        return @buckets
            .filter(([startA, endA, ...]) ->
                intersects([start, end], [startA, endA])
            )


# Dataset utility class for internal use only
class Dataset
    constructor: ({ @id,  @color, @source, @sourceParams, @index, @records,
                    @paths, @lineplot, @ordinal, @element, @histogramThreshold,
                    @histogramBinCount, @cluster, cacheRecords, cacheIdField,
                    debounceTime}) ->
        @fetchDebounced = debounce(@doFetch, debounceTime)
        @currentSyncState = 0

        @cache = new RecordCache(cacheIdField) if cacheRecords

    getSource: ->
        @source

    setSource: (@source) ->

    setRecords: (@records) ->

    getRecords: -> @records

    setPaths: (@paths) ->

    getPaths: -> @paths

    sync: (args...) ->
        @fetchDebounced(args...)

    doFetch: (start, end, callback) ->
        @currentSyncState += 1
        syncState = @currentSyncState
        fetched = (records, paths) =>
            # only update the timeslider when the state is still valid
            if syncState == @currentSyncState
                callback(records, paths)

        # sources conforming to the Source interface
        if @source and typeof @source.fetch == "function"
            source = (args...) => @source.fetch(args...)
        # sources that are functions
        else if typeof @source == "function"
            source = @source
        # no source, simply call the callback with the static records and paths
        else
            return callback(@records, @paths)

        if @cache
            @cache.fetch(start, end, @sourceParams, source, fetched)
        else
            source(start, end, @sourceParams, fetched)


# Interface for a source
class Source
    fetch: (start, end, params, callback) ->

module.exports = TimeSlider

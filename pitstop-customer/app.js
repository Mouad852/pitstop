var express = require('express');
var path = require('path');
var cookieParser = require('cookie-parser');
var logger = require('morgan');
var cors = require("cors");
const helmet = require('helmet');

//routes
var customersRouter = require('./routes/customers');

var app = express();

app.disable('x-powered-by');

// Sets X-Content-Type-Options, X-Frame-Options, Referrer-Policy, HSTS and
// friends. Must come before the routes to apply to their responses.
// ZAP: X-Content-Type-Options Header Missing [10021] on /api/customers/*
app.use(helmet());

app.use(logger('dev'));
app.use(express.json());
app.use(express.urlencoded({ extended: false }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, 'public')));
app.use(cors());

app.use('/api/customers', customersRouter);
 
module.exports = app;

// end-to-end pipeline demo — 2026-08-24

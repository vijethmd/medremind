const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');

const app = express();
app.use(cors());
app.use(express.json());

mongoose.connect('mongodb://127.0.0.1:27017/med_reminder_db')
    .then(() => console.log("✅ MongoDB Connected"))
    .catch(err => console.error(err));

const Medication = mongoose.model('Medication', new mongoose.Schema({
    name: String,
    pattern: String,
    relation: String,
    createdAt: { type: Date, default: Date.now }
}));

app.get('/api/get-meds', async (req, res) => {
    const meds = await Medication.find().sort({ createdAt: -1 });
    res.json(meds);
});

app.post('/api/save-med', async (req, res) => {
    const med = new Medication(req.body);
    await med.save();
    res.status(201).json(med);
});

app.delete('/api/med/:id', async (req, res) => {
    await Medication.findByIdAndDelete(req.params.id);
    res.json({ message: "Deleted" });
});

app.listen(3000, '0.0.0.0', () => console.log('🚀 Server on Port 3000'));